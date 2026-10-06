Feature: Commit planning analyzes from the branch point
  Commit planning reviews the net change since the branch split off the default
  branch, including commits already on the branch and uncommitted edits, so a
  restore toward that point is judged as the remaining edit. New commits still
  cover only files that are not yet committed.

  Scenario: Analysis diff includes committed and uncommitted edits
    Given a feature branch has a committed edit
    And the working tree has a further uncommitted edit
    When commit planning builds the analysis diff
    Then that diff contains the committed edit and the uncommitted edit

  Scenario: The new-commit diff stays the uncommitted edit
    Given a feature branch has a committed edit
    And the working tree has a further uncommitted edit
    When commit planning builds the diff of what the next commit will contain
    Then that diff contains the uncommitted edit
    And it does not present the already committed edit as a new change

  Scenario: No branch point leaves analysis on the uncommitted edit
    Given the branch has not split from the default branch
    And the working tree has an uncommitted edit
    When commit planning looks for a branch-point diff
    Then there is no separate branch-point diff
