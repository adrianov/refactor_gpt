Feature: Commit planning analyzes uncommitted changes
  Commit planning reviews the working tree against the last commit, so messages
  and code assessment describe only what the next commit will contain. Work
  already committed on the branch is line counts, not a patch.

  Scenario: The analysis diff is the uncommitted edit
    Given a feature branch has a committed edit
    And the working tree has a further uncommitted edit
    When commit planning builds the analysis diff
    Then that diff contains the uncommitted edit
    And it does not present the already committed edit as a new change

  Scenario: Already committed work is line counts
    Given a feature branch has a committed edit past the default branch
    And the working tree has a further uncommitted edit
    When commit planning looks up already committed work
    Then that context lists insert and delete counts
    And it does not include a patch of the committed edit

  Scenario: No default branch leaves only the uncommitted edit
    Given the repository has no recorded default branch
    And the working tree has an uncommitted edit
    When commit planning looks up already committed work
    Then there is no separate branch context
