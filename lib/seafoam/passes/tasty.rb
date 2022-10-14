# frozen_string_literal: true

require "tsort"

module Seafoam
  module Passes
    # The Tasty pass applies if the graph contains tastytruffle nodes.
    class TastyPass < Pass
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
        simplify_blocks(graph)
        simplify_whiles(graph)
        simplify_applies(graph)
        simplify_literals(graph)
        simplify_ops(graph)
        simplify_locals(graph)
      end

      private

      def hide_tree(node)
        node.props[:hidden] = true
        node.outputs.each do |edge|
          hide_tree(edge.to)
        end
      end

      def find_child_edge(node, name)
        node.outputs.find { |e| e.props[:name] == name }
      end
      def find_child(node, name)
        find_child_edge(node, name).to
      end

      def hide_nodes(graph)
        graph.nodes.each_value do |node|
          node_class = node.node_class
          if node_class.include?("Data") && node_class.include?("$")
            hide_tree(node)
          end
        end
      end

      def simplify_labels(graph)
        graph.nodes.each_value do |node|
          next if node.props[:label]

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
          next unless node.node_class.include?("OptimizedBlock")
          # Blocks point to OptimizedBlocks which contain a sequence of subtrees. We can elide the OptimizedBlocks.
          raise "Unexpected edges to OptimizedBlock" unless node.inputs.length == 1

          block = node.inputs[0].from

          node.outputs.each do |edge|
            graph.create_edge(block, edge.to, edge.props.merge({ synthetic: true }))
            edge.props[:hidden] = true
          end

          node.props[:hidden] = true

          # We also want to ensure the children of a block are ordered sequentially in the output.
          graph.add_rank(node.outputs.map(&:to))
        end
      end

      def simplify_whiles(graph)
        graph.nodes.each_value do |node|
          next unless node.node_class.include?("While") && !node.node_class.include?("Repeating")
          # Whiles point to OptimizedOSRLoopNodes, which point to WhileRepeatings which have a condition and body subtree.
          # We can elide the loop and repeating nodes.
          loop_node = find_child(node, "loopNode")
          repeating_node = find_child(loop_node, "repeatingNode")
          condition_node = find_child(repeating_node, "condition")
          body_node = find_child(repeating_node, "body")

          graph.create_edge(node, condition_node, { label: "cond", synthetic: true })
          graph.create_edge(node, body_node, { label: "body", synthetic: true })
          graph.add_rank([condition_node, body_node])
          loop_node.props[:hidden] = true
          repeating_node.props[:hidden] = true
        end
      end

      def simplify_applies(graph)
        argument_pattern = /arguments\[(\d+)\]/
        graph.nodes.each_value do |node|
          node_class = node.node_class
          next unless node_class.include?("Apply") && !node_class.include?("ArrayApply") && !node.props[:hidden]

          method = if node.props.key?("selector")
                     node.props["selector"].split(".")[-1]
                   else
                     node.props["signature"].split("(")[0]
                   end
          node.props["label"] = "Call(#{method})"

          # Sort argument edges
          outputs = node.outputs.dup
          receiver, rest = outputs.partition { |edge| edge.props[:name] == "receiver_" }
          arguments, rest = rest.partition do |edge|
            match = argument_pattern.match(edge.props[:name])
            if match
              edge.props[:argument_index] = match.captures[0].to_i
            end
            !match.nil?
          end
          arguments.sort_by! { |edge| edge.props[:argument_index] }
          (receiver + arguments + rest).each_with_index do |edge, i|
            node.outputs[i] = edge
          end

          # Set argument edge labels
          receiver.each do |edge|
            edge.props[:label] = "receiver"
          end
          arguments.each do |edge|
            edge.props[:label] = "arg#{edge.props[:argument_index]}"
          end
        end
      end

      def simplify_literals(graph)
        graph.nodes.each_value do |node|
          next unless node.node_class.include?("Literal")

          constant = node.props["constant"]
          node.props["label"] = "Constant(#{constant})"
        end
      end

      def convert_op(op)
        op[0] + op[1..].downcase
      end

      def simplify_ops(graph)
        graph.nodes.each_value do |node|
          if node.node_class.include?("IntArithmetic") || node.node_class.include?("IntComparison")
            node.props["label"] = "Int#{convert_op(node.props["op"])}"
            lhs = find_child(node, "lhs_")
            rhs = find_child(node, "rhs_")
            graph.add_rank([lhs, rhs])
            # lhs_edge.props[:label] = "lhs"
            # rhs_edge.props[:label] = "rhs"
          end
        end
      end

      def simplify_locals(graph)
        locals = {}
        local_pattern = /Local\((\w+), \w+(?:\[\])*\)/

        graph.nodes.dup.each_value do |node|
          next unless node.node_class.include?("Local")

          local = node.props["local"]
          if locals.key?(local)
            local_node = locals[local]
          else
            local_node = graph.create_node(graph.new_id, { synthetic: true, label: local, kind: "info", style: "rounded" })
            locals[local] = local_node
          end

          # This links a local access to a local. Creates a lot of visual noise, so I'll leave it commented out.
          # graph.create_edge(node, local_node, { kind: "info" })

          match = local_pattern.match(local)
          local_name = match.captures[0]
          node.props["label"] = "#{node.props["label"]}(#{local_name})"
        end
      end

    end
  end
end
