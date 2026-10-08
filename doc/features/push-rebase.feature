Feature: Push rebases onto a moved base branch
  When the default branch has new commits past this branch's branch point and
  replaying the branch onto it does not conflict, the push updates the branch
  onto that base and publishes the rewritten commits with a lease. The default
  branch itself is left as it is.

  Scenario: Clean replay onto a moved base is pushed with a lease
    Given a feature branch whose branch point is behind the default branch
    And replaying the feature branch onto the default branch has no conflicts
    And the feature branch already exists on the remote
    When the commit tool pushes
    Then it rebases the feature branch onto the default branch
    And it pushes with a force-with-lease

  Scenario: A remote default branch is fetched before the rebase
    Given a feature branch is behind the remote default branch
    And that remote update is not in the local repository yet
    And replaying onto the updated default branch has no conflicts
    When the commit tool pushes
    Then it fetches the remote default branch
    And it rebases the feature branch onto that updated default branch

  Scenario: A failed fetch keeps the known remote state
    Given a feature branch has a remote
    And that remote cannot be fetched
    When the commit tool pushes
    Then it warns that the fetch failed
    And it keeps using the remote state already known locally

  Scenario: A conflicting replay is not rebased
    Given a feature branch whose branch point is behind the default branch
    And replaying the feature branch onto the default branch conflicts
    When the commit tool pushes
    Then it leaves the feature branch in place
    And it pushes without a force-with-lease

  Scenario: Uncommitted edits are not rebased
    Given a feature branch whose branch point is behind the default branch
    And tracked files have uncommitted edits
    When the commit tool pushes
    Then it leaves the feature branch in place
    And it pushes without a force-with-lease

  Scenario: An up-to-date branch point is pushed as-is
    Given a feature branch whose branch point is the head of the default branch
    When the commit tool pushes
    Then it leaves the feature branch in place
    And it pushes without a force-with-lease

  Scenario: The default branch itself is not rebased
    Given the current branch is the default branch
    And the remote default branch has new commits
    When the commit tool pushes
    Then it leaves the branch in place
    And it pushes without a force-with-lease

  Scenario: A rebased branch that is not on the remote yet is published as a new branch
    Given a feature branch that has not been pushed
    And its branch point is behind the default branch
    And replaying onto the default branch has no conflicts
    When the commit tool pushes
    Then it rebases the feature branch onto the default branch
    And it pushes the branch as a new remote branch
