defmodule Rail.Domain.RunFailureTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.RunFailure

  test "changeset/2 validates required type" do
    valid_changeset = RunFailure.changeset(%RunFailure{}, %{type: :transient, message: "503"})
    assert valid_changeset.valid?

    invalid_changeset = RunFailure.changeset(%RunFailure{}, %{type: nil})
    refute invalid_changeset.valid?
    assert "can't be blank" in errors_on(invalid_changeset).type
  end

  test "factory/0 returns a valid struct" do
    failure = RunFailure.factory()
    assert failure.type == :transient
    assert failure.message == "503 Service Unavailable"
    assert failure.retryable == true
    assert failure.attempt == 1
  end

  test "constants max_auto_retries/0 and retry_backoff/0" do
    assert RunFailure.max_auto_retries() == 2
    assert RunFailure.retry_backoff() == [15, 60]
  end

  test "the CLI tripping over itself is transient" do
    assert RunFailure.transient?(
             "agy reported ERROR: Your previous response contained an improperly formatted function call. Retries remaining: 3"
           )

    assert RunFailure.transient?("Reattached to pid 12, which ended without reporting a result.")
    assert RunFailure.transient?("503 Service Unavailable")
    assert RunFailure.transient?("deadline exceeded")
    assert RunFailure.transient?("connection reset by peer")
    assert RunFailure.transient?("API rate limit exceeded")
    assert RunFailure.transient?("interrupted socket connection")
    assert RunFailure.transient?("temporary lock could not be acquired")
  end

  test "anything that would fail identically is not transient" do
    refute RunFailure.transient?(~s([claude-code:unrecognized_model] {"model":"claude-fable-5-1"}))
    refute RunFailure.transient?("No such CLI binary")
    refute RunFailure.transient?("not authenticated")
    refute RunFailure.transient?("permission denied")
  end

  test "a permanent reason wins over transient-sounding words inside it" do
    refute RunFailure.transient?("usage limit reached; try again later")
    refute RunFailure.transient?("401 unauthorized after connection reset")
  end

  test "an unclassified failure is treated as permanent" do
    refute RunFailure.transient?("Exited with code 2")
    refute RunFailure.transient?("")
    refute RunFailure.transient?("   ")
    refute RunFailure.transient?(nil)
    refute RunFailure.transient?(12_345)
  end

  test "transient?/1 and permanent?/1 on structs" do
    trans = %RunFailure{type: :transient}
    perm = %RunFailure{type: :permanent}

    assert RunFailure.transient?(trans)
    refute RunFailure.transient?(perm)

    assert RunFailure.permanent?(perm)
    refute RunFailure.permanent?(trans)
    assert RunFailure.permanent?("unrecognized_model")
  end

  test "classify/1 and classify/2 constructs %RunFailure{}" do
    classified_transient = RunFailure.classify("503 Service Unavailable", 1)
    assert classified_transient.type == :transient
    assert classified_transient.message == "503 Service Unavailable"
    assert classified_transient.exit_code == 1
    assert classified_transient.retryable == true
    assert classified_transient.attempt == 0

    classified_map =
      RunFailure.classify(%{
        "message" => "rate limit",
        "exit_code" => 2,
        "attempt" => 2
      })

    assert classified_map.type == :transient
    assert classified_map.retryable == false
    assert classified_map.attempt == 2

    classified_perm = RunFailure.classify("invalid api key")
    assert classified_perm.type == :permanent
    assert classified_perm.retryable == false
  end

  test "retry_delay/1 and retry_delay_ms/1 calculate backoff" do
    assert RunFailure.retry_delay(0) == 15
    assert RunFailure.retry_delay(1) == 15
    assert RunFailure.retry_delay(2) == 60
    assert is_nil(RunFailure.retry_delay(3))
    assert is_nil(RunFailure.retry_delay(4))
    assert is_nil(RunFailure.retry_delay(:invalid))

    assert RunFailure.retry_delay_ms(1) == 15_000
    assert RunFailure.retry_delay_ms(2) == 60_000
    assert is_nil(RunFailure.retry_delay_ms(3))
  end

  test "retryable?/1 and retryable?/2 checks" do
    assert RunFailure.retryable?(%RunFailure{retryable: true})
    refute RunFailure.retryable?(%RunFailure{retryable: false})

    assert RunFailure.retryable?(0)
    assert RunFailure.retryable?(1)
    refute RunFailure.retryable?(2)
    refute RunFailure.retryable?(3)

    assert RunFailure.retryable?("503 Service Unavailable", 0)
    assert RunFailure.retryable?("503 Service Unavailable", 1)
    refute RunFailure.retryable?("503 Service Unavailable", 2)
    refute RunFailure.retryable?("unrecognized model", 0)

    assert RunFailure.retryable?("503 Service Unavailable")
    refute RunFailure.retryable?("unrecognized model")
    refute RunFailure.retryable?(:invalid)
  end
end
