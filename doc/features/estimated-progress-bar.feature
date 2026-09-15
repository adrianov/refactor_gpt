Feature: Estimated-speed progress bar
  While a tool waits for a model response, a progress bar shows that the request is
  alive and roughly how far along it should be, so long planning or review waits feel
  accountable instead of silent.

  Scenario: Bar advances while the response is pending
    Given a request is sent with a progress label
    When the response has not arrived yet
    Then the bar advances steadily at the estimated response speed
    And it keeps moving even after the initial estimate is exhausted

  Scenario: Bar speed calibrates to the real response pace
    Given previous requests measured their real pace
    When the next request's bar is shown
    Then it advances at a speed blended from the stored estimate and recent measurements
    And the stored estimate updates again when the request finishes
