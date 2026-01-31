# frozen_string_literal: true

# Builds list of descendant PIDs for a parent PID via ps and BFS. Extracted to reduce AgentExecutor length.
module ProcessDescendants
  module_function

  def get_all_descendants(parent_pid)
    p_to_c = build_parent_to_children
    return [] if p_to_c.empty?

    bfs_descendants(p_to_c, parent_pid.to_i)
  end

  def build_parent_to_children
    output = `ps -eo ppid,pid 2>/dev/null`
    return {} if output.empty?

    p_to_c = Hash.new { |h, k| h[k] = [] }
    output.each_line.map(&:split).each do |ppid, pid|
      p_to_c[ppid.to_i] << pid.to_i if ppid && pid
    end
    p_to_c
  end

  def bfs_descendants(p_to_c, root)
    descendants = []
    queue = [root]
    while queue.any?
      curr = queue.shift
      children = p_to_c[curr]
      next unless children

      descendants.concat(children)
      queue.concat(children)
    end
    descendants
  end
end
