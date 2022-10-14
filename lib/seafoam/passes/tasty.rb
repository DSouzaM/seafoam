# frozen_string_literal: true

require "tsort"

module Seafoam
  module Passes
    # The Truffle pass applies if it looks like it was compiled by Truffle.
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

      def simplify_applies(graph)
        argument_pattern = /arguments\[(\d+)\]/
        graph.nodes.each_value do |node|
          node_class = node.node_class
          next unless node_class.include?("Apply") && !node.props[:hidden]

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

      def convert_arithmetic_op(op)
        op[0] + op[1..].downcase
      end

      def simplify_ops(graph)
        graph.nodes.each_value do |node|
          if node.node_class.include?("IntArithmetic")
            node.props["label"] = "Int#{convert_arithmetic_op(node.props["op"])}"
          end
        end
      end

      def simplify_locals(graph)
        locals = {}
        local_pattern = /Local\((\w+), \w+\)/

        graph.nodes.dup.each_value do |node|
          next unless node.node_class.include?("Local")

          local = node.props["local"]
          if locals.key?(local)
            local_node = locals[local]
          else
            local_node = graph.create_node(graph.new_id, { synthetic: true, label: local, kind: "info", style: "rounded" })
            locals[local] = local_node
          end

          graph.create_edge(node, local_node, { kind: "info" })

          match = local_pattern.match(local)
          local_name = match.captures[0]
          node.props["label"] = "#{node.props["label"]}(#{local_name})"
        end
      end

    end
  end
end
