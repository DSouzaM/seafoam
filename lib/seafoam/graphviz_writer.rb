# frozen_string_literal: true

module Seafoam
  # A writer from graphs to the Graphviz DOT format, including all the
  # formatting.
  class GraphvizWriter
    def initialize(stream)
      @stream = stream
    end

    # Write a graph.
    def write_graph(graph, hidpi = false, draw_blocks = false)
      inline_attrs = {}
      attrs = {}
      attrs[:dpi] = 200 if hidpi
      attrs[:bgcolor] = "white"
      start_graph(attrs)
      write_nodes(inline_attrs, graph, draw_blocks)
      write_edges(inline_attrs, graph)
      write_ranks(graph)
      end_graph
    end

    def start_graph(attrs)
      @stream.puts "digraph G {"
      @stream.puts "  graph #{write_attrs(attrs)};"
    end

    def end_graph
      @stream.puts "}"
    end

    private

    # Write node declarations.
    def write_nodes(inline_attrs, graph, draw_blocks)
      drawn_in_blocks = []

      if draw_blocks
        graph.blocks.each do |block|
          next if block.nodes.all? { |n| n.props[:hidden] || n.props[:inlined] }

          start_subgraph(block.id)

          block.nodes.each do |node|
            next if node.props[:hidden] || node.props[:inlined]

            write_node("    ", inline_attrs, node)
            drawn_in_blocks.push(node)
          end

          end_subgraph
        end
      end

      (graph.nodes.values - drawn_in_blocks).each do |node|
        write_node("  ", inline_attrs, node)
      end
    end

    def start_subgraph(id)
      @stream.puts "  subgraph cluster_block#{id} {"
      @stream.puts '    fontname = "Arial";'
      @stream.puts "    label = \"B#{id}\";"
      @stream.puts "    style = filled;"
      @stream.puts "    color = #{DARK_YELLOW.inspect};"
      @stream.puts "    fillcolor = #{LIGHT_YELLOW.inspect};"
    end

    def end_subgraph
      @stream.puts "  }"
    end

    def write_node(indent, inline_attrs, node)
      # We're going to build up a hash of Graphviz drawing attributes.
      attrs = {}

      # The node is hidden, and it's not going to be inlined above any
      # other node.
      if node.props[:hidden] && !node.props[:inlined]
        # If the node has any adjacent nodes that are not hidden, and are
        # shaded, then we need to declare the node but make it invisible so
        # the edge appears, pointing off into space, but the node does not.
        if node.adjacent.any? { |a| !a.props[:hidden] && a.props[:spotlight] == "shaded" }
          attrs[:style] = "invis"
          attrs[:label] = ""
          output_node(indent, "node#{node.id}", attrs)
        end
      else
        # This is a visible node.

        # Give it a label.
        attrs[:label] = if node.props[:label]
          "#{node.id} #{node.props[:label]}"
        else
          # If we really still don't have a label, just use the ID.
          node.id.to_s
        end

        # Basic attributes for a node.
        attrs[:shape] = "rectangle"
        attrs[:fontname] = "Arial"
        attrs[:style] = node.props[:style] || "filled"
        attrs[:color] = "black"

        # Color depends on the kind of node.
        back_color, fore_color = NODE_COLORS[node.props[:kind]]
        attrs[:fillcolor] = back_color
        attrs[:fontcolor] = fore_color

        # If the node is shaded, convert the attributes to the shaded
        # version.
        attrs = shade(attrs) if node.props[:spotlight] == "shaded"

        if node.props[:inlined]
          # If the node is to be inlined then draw it smaller and a different
          # shape.
          attrs[:shape] = "oval"
          # attrs[:fontsize] = "8"

          # Just record these attributes for where it's used by other nodes
          # so it can be drawn above them - don't actually declare a node.
          inline_attrs[node.id] = attrs
        else
          attrs[:shape] = "diamond" if node.props[:kind] == "calc"

          # Declare the node.
          output_node(indent, "node#{node.id}", attrs)
        end
      end
    end

    def output_node(indent, id, attrs)
      @stream.puts "#{indent}#{id} #{write_attrs(attrs)};"
    end

    # Write edge declarations.

    def write_edges(inline_attrs, graph)
      graph.edges.each do |edge|
        # Skip the edge if it's from a node that is hidden and it doesn't point
        # to a shaded node.
        next if edge.from.props[:hidden] && edge.to.props[:spotlight] != "shaded"

        # Skip the edge if it's to a node that is hidden and it doesn't come
        # from a shaded node.
        next if edge.to.props[:hidden] && edge.from.props[:spotlight] != "shaded"

        # Skip the edge if it's hidden itself
        next if edge.props[:hidden]

        write_edge(inline_attrs, edge)
      end
    end

    def write_edge(inline_attrs, edge)
      # We're going to build up a hash of Graphviz drawing attributes.
      attrs = {}

      label = edge.props[:label]
      if edge.from.props[:out_annotation]
        label = "#{label} #{edge.from.props[:out_annotation]}"
      end
      attrs[:label] = label

      # Basic edge attributes.
      attrs[:fontname] = "arial"
      color = EDGE_COLORS[edge.props[:kind]]
      attrs[:color] = EDGE_COLORS[edge.props[:kind]]
      attrs[:fontcolor] = color

      # Properties depending on the kind of edge.
      case edge.props[:kind]
      when "control"
        attrs[:penwidth] = 2
      when "loop"
        attrs[:penwidth] = 4
      when "info"
        attrs[:style] = "dashed"
      end

      # Reversed edges.
      attrs[:dir] = "back" if edge.props[:reverse]

      # Convert attributes to shaded if any edges involved are shaded.
      attrs = shade(attrs) if edge.nodes.any? { |n| n.props[:spotlight] == "shaded" }

      # Does this edge come from an inlined node?

      if edge.from.props[:inlined]
        # Don't draw inlined nodes to hidden nodes.
        unless edge.to.props[:hidden]

          # An inlined edge is drawn as a new version of the from-node and an
          # edge from that new version directly to the to-node. With only one
          # user it's a short edge and the from-node is show directly above the
          # to-node.

          node_attrs = if edge.to.props[:spotlight] == "shaded"
            # Draw inlined edges to shaded nodes as invisible.
            { label: "", style: "invis" }
          else
            # Get attributes from when we went through nodes earlier.
            inline_attrs[edge.from.id]
          end

          # Inlined nodes skip the arrow for simplicity.
          attrs[:arrowhead] = "none"
          # attrs[:fontsize] = "8"

          # Declare a new node just for this user.
          output_node("  ", "inline#{edge.from.id}x#{edge.to.id}", node_attrs)

          # Declare the edge.
          output_edge("inline#{edge.from.id}x#{edge.to.id}", "node#{edge.to.id}", attrs)
        end
      else
        # Declare the edge.
        output_edge("node#{edge.from.id}", "node#{edge.to.id}", attrs)
      end
    end

    def output_edge(from, to, attrs)
      @stream.puts "  #{from} -> #{to} #{write_attrs(attrs)};"
    end

    # Return attributes for a node or edge modified to 'shade' them in terms
    # the spotlight functionality - so basically make them light grey.
    def shade(attrs)
      attrs = attrs.dup
      attrs[:color] = ICE_STONE
      attrs[:fontcolor] = ICE_STONE
      attrs[:fillcolor] = DUST
      attrs
    end

    # Create a new subgraph with invisible edges to indicate rank. (https://stackoverflow.com/a/64007295)
    def write_ranks(graph)
      graph.ranks.each do |rank|
        edges = rank.map{|node| "node#{node.id}"}.join(" -> ")
        @stream.puts("  {")
        @stream.puts("    rank=same;")
        @stream.puts("    edge[style=invis];")
        @stream.puts("    #{edges};")
        @stream.puts("    rankdir=LR;")
        @stream.puts("  }")
      end
    end

    # Write a hash of key-value attributes into the DOT format.
    def write_attrs(attrs)
      "[" + attrs.reject { |_k, v| v.nil? }.map { |k, v| "#{k}=#{v.inspect}" }.join(",") + "]"
    end

    # Color theme.

    EDGE_COLORS = {
      "info" => BIG_STONE,
      "control" => AMARANTH,
      "loop" => AMARANTH,
      "data" => KEPPEL,
      "other" => BLACK,
    }

    NODE_COLORS = {
      "info" => [DUST, BLACK],
      "input" => [WHITE_ICE, BLACK],
      "control" => [CARISSMA, BLACK],
      "memory" => [LIGHT_PURPLE, BLACK],
      "call" => [AMARANTH, WHITE],
      "sync" => [AMARANTH, WHITE],
      "alloc" => [AMARANTH, WHITE],
      "virtual" => [BIG_STONE, WHITE],
      "guard" => [ORANGE, BLACK],
      "calc" => [KEPPEL, BLACK],
      "other" => [DUST, BLACK],
    }
  end
end
