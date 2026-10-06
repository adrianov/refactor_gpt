Feature: Review diff from the branch point
  The completion check shows the merge-request diff from where the branch
  split off the default branch. Committed edits and uncommitted edits are
  both included, including files that are already committed and clean.

  Scenario: Committed and uncommitted edits are both attached
    Given a feature branch has a committed edit in one file
    And the working tree edits a different file
    When the completion check attaches a diff
    Then the diff contains the committed edit and the uncommitted edit
    And files unchanged since the branch point are absent

  Scenario: Net change since the branch point is attached
    Given a feature branch that diverged from the default branch
    And the working tree has further uncommitted edits
    When the completion check attaches a diff
    Then the diff starts at the branch point and includes those uncommitted edits

  Scenario: Restored lines are not shown as deletions
    Given a feature branch whose latest commit rewrote a file
    And the working tree restores that file toward the default branch, leaving a small edit
    When the completion check attaches a diff
    Then the diff is the remaining edit against the default branch
    And the restored rewrite is absent

  Scenario: Working tree matches the branch point
    Given a feature branch whose latest commit rewrote a file
    And the working tree restores that file to the branch point
    When the completion check attaches a diff
    Then the diff reports no net changes since the branch point

  Scenario: Remote default branch is the branch point
    Given the remote names a default branch
    And another branch tip also exists
    When the completion check attaches a diff
    Then the branch point is the merge-base with that remote default branch

  Scenario: No default branch still shows uncommitted edits
    Given a repository with no default branch to compare
    And the working tree has uncommitted edits
    When the completion check attaches a diff
    Then the diff is the uncommitted edit against the latest commit
