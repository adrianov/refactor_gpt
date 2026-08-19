# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class TestGitStatusPaths < Minitest::Test
  PORCELAIN = <<~STATUS
    ## main
    R  app/javascript/diary/day_sheet.js -> app/javascript/diary/day/sheet.js
    D  app/javascript/diary/day_budget.js
     M app/models/user.rb
    D  app/models/gone.rb
  STATUS

  def test_filenames_include_rename_source_and_destination
    status = <<~STATUS
      ## main...origin/main
       M app/models/user.rb
      R100 old.rb -> new.rb
    STATUS
    assert_equal %w[app/models/user.rb old.rb new.rb], GitStatusPaths.filenames(status)
  end

  def test_partners_include_rename_and_sibling_delete
    selected = ["app/javascript/diary/day/sheet.js"]
    partners = GitStatusPaths.partners_for(selected, PORCELAIN)
    assert_includes partners, "app/javascript/diary/day_sheet.js"
    assert_includes partners, "app/javascript/diary/day/sheet.js"
    assert_includes partners, "app/javascript/diary/day_budget.js"
    refute_includes partners, "app/models/user.rb"
    refute_includes partners, "app/models/gone.rb"
  end

  def test_partners_empty_without_selected_paths
    assert_empty GitStatusPaths.partners_for([], PORCELAIN)
  end

  def test_expand_partners_empty_without_selected_paths
    assert_empty GitStatusPaths.expand_partners([])
  end
end
