# frozen_string_literal: true

require "tsort"

module Seafoam
  module Passes
    # The Tasty pass applies if the graph contains tastytruffle nodes.
    class TastyPass < Pass
      attr_reader :ranks

      def initialize(options)
        super
        @ranks = []
      end

      class << self
        def applies?(graph)
          graph.nodes.values.any? do |v|
            node_class = v.props[:node_class]
            next unless node_class

            node_class[:node_class].include?("org.tastytruffle.core")
          end
        end
      end

      def apply(graph)
        hide_nodes(graph)
        simplify_labels(graph)
        simplify_locals(graph)
        simplify_fields(graph)
        simplify_ifs(graph)
        simplify_whiles(graph)
        simplify_applies(graph)
        simplify_literals(graph)
        simplify_ops(graph)
        simplify_blocks(graph)
        generate_ranks(graph)
      end

      private

      def hide_tree(node)
        node.props[:hidden] = true
        node.outputs.each do |edge|
          hide_tree(edge.to)
        end
      end

      def is_visible(node_or_edge)
        !node_or_edge.props.fetch(:hidden, false)
      end


      def find_child_edge(node, name)
        node.outputs.find { |e| e.props[:name] == name && is_visible(e) }
      end

      def find_child(node, name)
        edge = find_child_edge(node, name)
        raise "Couldn't find child #{name}" unless edge

        edge.to
      end

      def hide_nodes(graph)
        graph.nodes.each_value do |node|
          node_class = node.node_class
          if node_class&.include?("Data") && node_class&.include?("$")
            hide_tree(node)
          end
        end
      end

      # Register a node and a function to be applied to it to generate a rank. We have to defer rank generation until
      # after all passes: if we generate a rank after pass_i, some later pass_j (j > i) may change the children, and
      # then our rank won't include any new children.
      def register_rank(node, fn)
        ranks.push([node, fn])
      end

      # Rank generator using the order of output edges.
      def rank_by_output_order
        ->(node) { node.outputs.map(&:to).filter { |node| is_visible(node) } }
      end

      # Rank generator based on names of edges.
      def rank_by_name(*names)
        lambda do |node|
          names.map { |name| find_child(node, name) }
        end
      end

      # Rank generator for apply nodes, which puts the receiver and numbered arguments in order.
      def rank_by_argument_order
        lambda do |node|
          receiver, rest = node.outputs.partition { |edge| edge.props[:name] == "receiver_" }
          arguments, rest = rest.partition { |edge| edge.props.key?(:argument_index) }
          arguments.sort_by! { |edge| edge.props[:argument_index] }
          (receiver + arguments + rest).map(&:to).filter { |node| is_visible(node) }
        end
      end

      def simplify_labels(graph)
        graph.nodes.each_value do |node|
          next if node.props[:label] || !node.node_class

          node_class = node.node_class

          if node_class.end_with?("DefDefNode")
            node.props["label"] = "Method(#{node.props["symbol"]})"
          elsif node_class.end_with?("NodeGen")
            node.props["label"] = node.props["label"].delete_suffix("NodeGen")
          elsif node_class.end_with?("Node")
            node.props["label"] = node.props["label"].delete_suffix("Node")
          end
        end
      end

      def simplify_blocks(graph)
        graph.nodes.each_value do |node|
          next unless node.node_class&.include?("OptimizedBlock")
          # Blocks point to OptimizedBlocks which contain a sequence of subtrees. We can elide the OptimizedBlocks.
          raise "Unexpected edges to OptimizedBlock" unless node.inputs.length == 1

          block = node.inputs[0].from

          node.outputs.each do |edge|
            graph.create_edge(block, edge.to, edge.props.merge({ synthetic: true }))
            edge.props[:hidden] = true
          end

          node.props[:hidden] = true

          register_rank(node, rank_by_output_order)
        end
      end

      def simplify_ifs(graph)
        graph.nodes.each_value do |node|
          next unless node.node_class&.include?("If")

          cond = find_child_edge(node, "condTerm")
          thens = find_child_edge(node, "thenTerm")
          elses = find_child_edge(node, "elseTerm")

          cond.props[:label] = "cond"
          thens.props[:label] = "then"
          elses.props[:label] = "else"

          register_rank(node, rank_by_name("condTerm", "thenTerm", "elseTerm"))
        end
      end

      def simplify_whiles(graph)
        graph.nodes.each_value do |node|
          next unless node.node_class&.include?("While") && !node.node_class&.include?("Repeating")

          # Whiles point to OptimizedOSRLoopNodes, which point to WhileRepeatings which have a condition and body subtree.
          # We can elide the loop and repeating nodes.
          loop_node = find_child(node, "loopNode")
          repeating_node = find_child(loop_node, "repeatingNode")
          condition_node = find_child(repeating_node, "condition")
          body_node = find_child(repeating_node, "body")

          graph.create_edge(node, condition_node, { label: "cond", name: "condition", synthetic: true })
          graph.create_edge(node, body_node, { label: "body", name: "body", synthetic: true })

          loop_node.props[:hidden] = true
          repeating_node.props[:hidden] = true

          register_rank(node, rank_by_name("condition", "body"))
        end
      end

      def simplify_applies(graph)
        argument_pattern = /arguments\[(\d+)\]/
        graph.nodes.each_value do |node|
          node_class = node.node_class
          next unless node_class&.include?("Apply") && !node_class&.include?("ArrayApply") && !node.props[:hidden]

          method = if node.props.key?("selector")
                     node.props["selector"].split(".")[-1]
                   else
                     node.props["signature"].split("(")[0]
                   end
          node.props["label"] = "Call(#{method})"

          outputs = node.outputs.dup
          receiver, rest = outputs.partition { |edge| edge.props[:name] == "receiver_" }
          arguments, _rest = rest.partition do |edge|
            match = argument_pattern.match(edge.props[:name])
            if match
              edge.props[:argument_index] = match.captures[0].to_i
            end
            !match.nil?
          end

          # Set argument edge labels
          receiver.each do |edge|
            edge.props[:label] = "receiver"
          end
          arguments.each do |edge|
            edge.props[:label] = "arg#{edge.props[:argument_index]}"
          end

          register_rank(node, rank_by_argument_order)
        end
      end

      def simplify_literals(graph)
        graph.nodes.each_value do |node|
          next unless node.node_class&.include?("Literal")

          constant = node.props["constant"]
          node.props["label"] = "Constant(#{constant})"
        end
      end

      def convert_op(op)
        op[0] + op[1..].downcase
      end

      def simplify_ops(graph)
        graph.nodes.each_value do |node|
          if node.node_class&.include?("IntArithmetic") || node.node_class&.include?("IntComparison")
            node.props["label"] = "Int#{convert_op(node.props["op"])}"
            register_rank(node, rank_by_name("lhs_", "rhs_"))
          end
        end
      end

      def simplify_locals(graph)
        locals = {}
        local_pattern = /Local\((\w+), \w+(?:\[\])*\)/

        graph.nodes.dup.each_value do |node|
          next unless node.node_class&.include?("Local")

          local = node.props["local"]

          # # We can't determine the type of a field access the same way we can with a local, so maybe we shouldn't
          # # render locals as nodes in the graph.
          # if locals.key?(local)
          #   local_node = locals[local]
          # else
          #   local_node = graph.create_node(graph.new_id, { synthetic: true, label: local, kind: "info", style: "rounded" })
          #   locals[local] = local_node
          # end

          # This links a local access to a local. Creates a lot of visual noise, so I'll leave it commented out.
          # graph.create_edge(node, local_node, { kind: "info" })

          match = local_pattern.match(local)
          local_name = match.captures[0]
          node.props["label"] = "#{node.props["label"]}(#{local_name})"
        end
      end

      def replace_child_edge(old_edge, new_edge)
        pred = old_edge.from
        old_index = pred.outputs.find_index(old_edge)
        new_index = pred.outputs.find_index(new_edge)
        pred.outputs[old_index] = new_edge
        pred.outputs[new_index] = old_edge
        old_edge.props[:hidden] = true
      end

      def simplify_fields(graph)
        graph.nodes.dup.each_value do |node|
          next unless node.node_class&.include?("Field")

          is_write = node.node_class.include?("Write")
          if node.node_class.include?("Indirect")
            # FieldXIndirect -> Apply -> args can be replaced with CallFieldX(fieldName) -> args
            apply_node = find_child(node, "applyNode")

            label = is_write ? "CallFieldWrite" : "CallFieldRead"
            field_name = node.props["fieldSymbol"]

            accessor_node = graph.create_node(graph.new_id, { synthetic: true, label: "#{label}(#{field_name})" })
            node.inputs.each do |edge|
              new_edge = graph.create_edge(edge.from, accessor_node, edge.props.merge({ synthetic: true }))
              replace_child_edge(edge, new_edge)
            end

            receiver, rest = apply_node.outputs.partition { |edge| edge.props[:name] == "receiver_" }
            receiver.each do |edge|
              new_edge = graph.create_edge(accessor_node, edge.to, edge.props.merge({ synthetic: true }))
              new_edge.props[:label] = "receiver"
            end
            rest.each do |edge|
              graph.create_edge(accessor_node, edge.to, edge.props.merge({ synthetic: true }))
            end

            node.props[:hidden] = true
            apply_node.props[:hidden] = true

            register_rank(accessor_node, rank_by_argument_order) if is_write
          else # Direct field node
            # FieldXDirect -> args can be relabeled to FieldX(fieldName) -> args
            label = is_write ? "FieldWrite" : "FieldRead"
            field_name = node.props["selector"]
            node.props[:label] = "#{label}(#{field_name})"

            receiver, _rest = node.outputs.partition { |edge| edge.props[:name] == "receiver_" }
            receiver.each do |edge|
              edge.props[:label] = "receiver"
            end

            register_rank(node, rank_by_argument_order) if is_write
          end
        end
      end

      # By default, graph nodes are rendered in the order they're declared. We add ranks to specify an ordering between
      # specific nodes.
      # This pass should be run after all others, so that any inserted/replaced nodes are included in the ranks.
      def generate_ranks(graph)
        @ranks.each do |pair|
          node, fn = pair
          graph.add_rank(fn.call(node))
        end
      end

    end
  end
end
