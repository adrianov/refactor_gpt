Feature: Configurable reasoning effort for commit planning
  The commit planner lets the user choose how much reasoning the model spends
  on planning, trading planning depth against speed, so a routine batch stays
  fast while a risky batch can ask for deeper analysis.

  Scenario: Default keeps planning fast
    Given the user has not configured a reasoning effort
    When the tool plans commits for the working tree
    Then the planner model is asked for low reasoning effort

  Scenario: User-selected effort is honored
    Given the user configured high reasoning effort in the app settings
    When the tool plans commits for the working tree
    Then the planner model is asked for high reasoning effort

  Scenario: Unsupported effort value stops the run before any request
    Given the user configured an unsupported reasoning effort in the app settings
    When the tool starts planning commits
    Then it stops with a message naming the supported values
    And no model request is sent

  Scenario: Blank effort value behaves as unconfigured
    Given the app settings contain an empty reasoning effort entry
    When the tool plans commits for the working tree
    Then the planner model is asked for low reasoning effort
