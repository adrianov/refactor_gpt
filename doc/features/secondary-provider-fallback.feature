Feature: Secondary provider fallback
  When the primary LLM provider stops serving requests for a reason that will not
  recover during the run, the tools retry once through a preconfigured secondary
  provider instead of dying, so a long refactoring or commit session survives a
  provider outage.

  Background:
    Given a configured secondary provider with its own API key, base URL, and model

  Scenario: Primary provider hits an unrecoverable usage limit
    Given the primary provider rejects a request with an unrecoverable usage-limit error
    When the client resends the same conversation
    Then it is served by the secondary provider with the secondary model
    And later requests in the same run keep using the secondary provider

  Scenario: Secondary provider fails unrecoverably too
    Given the fallback was already used once in this run
    When the secondary provider also rejects the request with an unrecoverable error
    Then the run stops with the secondary provider's error

  Scenario: No secondary provider is configured
    Given no secondary provider is configured
    When the primary provider fails unrecoverably
    Then the run stops immediately with the primary provider's error
