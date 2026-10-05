defmodule Rail.Tools.Schemas.BackendTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Tools.Schemas.Backend

  test "changeset/2 validates the config the user owns" do
    changeset = Backend.changeset(%Backend{}, %{name: nil, executable_path: nil})
    refute changeset.valid?
    assert %{name: ["can't be blank"], executable_path: ["can't be blank"]} = errors_on(changeset)

    invalid_name = Backend.changeset(%Backend{}, %{name: "unknown_backend", executable_path: "/usr/bin/true"})
    refute invalid_name.valid?
    assert %{name: ["is invalid"]} = errors_on(invalid_name)

    valid = Backend.changeset(%Backend{}, %{name: :claude, executable_path: "  /usr/bin/claude  "})
    assert valid.valid?
    assert Ecto.Changeset.get_field(valid, :executable_path) == "/usr/bin/claude"
  end

  test "changeset/2 trims the label and leaves a blank one unset" do
    labelled = Backend.changeset(%Backend{}, %{name: :claude, executable_path: "/usr/bin/claude", label: " work "})
    assert Ecto.Changeset.get_field(labelled, :label) == "work"

    blank = Backend.changeset(%Backend{}, %{name: :claude, executable_path: "/usr/bin/claude", label: "  "})
    assert Ecto.Changeset.get_field(blank, :label) == nil
  end

  test "config_dir/1 gives each backend its own directory under Rail's backends root" do
    root = Application.fetch_env!(:rail, :backends_root)

    assert Backend.config_dir(%Backend{id: "bkd_one"}) == Path.join(root, "bkd_one")
    refute Backend.config_dir(%Backend{id: "bkd_one"}) == Backend.config_dir(%Backend{id: "bkd_two"})
  end

  test "env_var/1 names the variable each CLI reads its config directory from" do
    assert Backend.env_var(:claude) == "CLAUDE_CONFIG_DIR"
    assert Backend.env_var(:codex) == "CODEX_HOME"
    assert Backend.env_var(:agy) == nil
  end

  test "names/0 returns all supported backend atoms" do
    assert Backend.names() == [:claude, :agy, :codex]
  end

  test "usage_changeset/2 validates required fields and status inclusion" do
    changeset = Backend.usage_changeset(%Backend{}, %{name: nil, status: nil})
    refute changeset.valid?
    assert %{name: ["can't be blank"], status: ["can't be blank"]} = errors_on(changeset)

    invalid_status = Backend.usage_changeset(%Backend{}, %{name: :claude, status: "unknown"})
    refute invalid_status.valid?
    assert %{status: ["is invalid"]} = errors_on(invalid_status)

    for status <- Backend.statuses() do
      valid = Backend.usage_changeset(%Backend{}, %{name: :claude, status: status})
      assert valid.valid?
      assert Ecto.Changeset.get_field(valid, :status) == status
    end
  end

  test "usage_changeset/2 leaves the user's config alone" do
    backend =
      Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: "/usr/bin/claude"}))

    updated =
      backend
      |> Backend.usage_changeset(%{
        name: :claude,
        status: :ready,
        account_label: "user@example.com",
        executable_path: "/tmp/hijacked",
        models: [%{id: "wiped"}]
      })
      |> Repo.update!()

    assert updated.executable_path == "/usr/bin/claude"
    assert updated.status == :ready
    assert updated.account_label == "user@example.com"
  end

  test "usage_changeset/2 casts embedded usage and persists to database" do
    backend =
      Repo.insert!(
        Backend.usage_changeset(%Backend{}, %{
          name: :agy,
          status: :ready,
          usage: [
            %{
              name: "Antigravity Limits",
              count: 2,
              details: %{"windows" => [%{"label" => "5-Hour", "remaining_percent" => 95.0}]}
            }
          ]
        })
      )

    assert backend.id =~ ~r/^bkd_/
    assert backend.name == :agy
    assert backend.executable_path == ""
    assert [%Backend.Usage{name: "Antigravity Limits", count: 2, details: details} = group] = backend.usage
    assert %{"windows" => [%{"label" => "5-Hour", "remaining_percent" => 95.0}]} = details

    # The usage groups reach the browser as JSON, so the embed has to encode.
    assert {:ok, json} = Jason.encode(group)
    assert {:ok, %{"name" => "Antigravity Limits", "count" => 2}} = Jason.decode(json)
  end

  test "usage_changeset/2 requires a group name and a non-negative count" do
    missing_name = Backend.usage_changeset(%Backend{}, %{name: :agy, status: :ready, usage: [%{count: 1}]})
    refute missing_name.valid?
    assert %{usage: [%{name: ["can't be blank"]}]} = errors_on(missing_name)

    negative_count =
      Backend.usage_changeset(%Backend{}, %{name: :agy, status: :ready, usage: [%{name: "A", count: -1}]})

    refute negative_count.valid?
    assert %{usage: [%{count: ["must be greater than or equal to 0"]}]} = errors_on(negative_count)
  end

  test "one kind may be configured any number of times" do
    attrs = %{name: :claude, executable_path: "/usr/bin/claude"}
    Repo.insert!(Backend.changeset(%Backend{}, attrs))

    assert {:ok, %Backend{}} = Repo.insert(Backend.changeset(%Backend{}, Map.put(attrs, :label, "work")))
  end

  describe "calculate_standing/3" do
    setup do
      now = ~U[2026-10-05 12:00:00Z]

      # An account's usage as a probe stores it: `{label, percent left, hours to its reset}`.
      account = fn windows ->
        %Backend{
          usage: [
            %Backend.Usage{
              name: "Limits",
              details: %{
                "windows" =>
                  for {label, percent, hours} <- windows do
                    at = if hours, do: now |> DateTime.shift(second: round(hours * 3600)) |> DateTime.to_iso8601()
                    %{"label" => label, "remaining_percent" => percent, "resets_at" => at}
                  end
              }
            }
          ]
        }
      end

      %{account: account, now: now}
    end

    test "a weekly window about to reset stands above more left that must last for days", %{account: account, now: now} do
      soon = account.([{"Session", 90.0, 2}, {"Weekly", 30.0, 6}])
      later = account.([{"Session", 90.0, 2}, {"Weekly", 60.0, 120}])

      assert Backend.calculate_standing(soon, "claude-opus-5-5", now).standing >
               Backend.calculate_standing(later, "claude-opus-5-5", now).standing
    end

    test "a nearly spent 5-hour window holds an account below one with room in both", %{account: account, now: now} do
      tight = account.([{"Session", 10.0, 4}, {"Weekly", 95.0, 100}])
      roomy = account.([{"5-Hour", 70.0, 3}, {"Weekly", 50.0, 72}])

      assert %{standing: tight_standing, tightest: %{kind: :five_hour, label: "5-hour"}} =
               Backend.calculate_standing(tight, "claude-opus-5-5", now)

      assert Backend.calculate_standing(roomy, "claude-opus-5-5", now).standing > tight_standing
    end

    test "a window at 0% leaves the account used up until its last spent window resets", %{account: account, now: now} do
      spent = account.([{"Session", 0.0, 2}, {"Weekly", 0.0, 30}])
      weekly_reset = DateTime.shift(now, hour: 30)

      assert %{standing: +0.0, used_up: [%{kind: :five_hour}, %{kind: :weekly}], resets_at: ^weekly_reset} =
               Backend.calculate_standing(spent, "claude-opus-5-5", now)
    end

    test "a window whose reset has passed counts as fresh without a refresh", %{account: account, now: now} do
      reset = account.([{"Session", 0.0, -1}])

      assert %{used_up: [], standing: 100.0, tightest: %{remaining_percent: 100.0}} =
               Backend.calculate_standing(reset, "claude-opus-5-5", now)
    end

    test "a model's weekly window counts only for its own model", %{account: account, now: now} do
      opus_spent = account.([{"Weekly · Opus 5.5", 0.0, 24}, {"Weekly · Sonnet", 80.0, 24}])

      assert %{used_up: [%{kind: :model_weekly, label: "Weekly · Opus 5.5"}]} =
               Backend.calculate_standing(opus_spent, "claude-opus-5-5", now)

      assert %{used_up: [], tightest: %{label: "Weekly · Sonnet"}} =
               Backend.calculate_standing(opus_spent, "claude-sonnet-5-5", now)
    end

    test "an account reporting none of the windows ranks as fresh, and unmeasured or other windows are ignored", %{
      account: account,
      now: now
    } do
      assert %{standing: 100.0, tightest: nil, used_up: [], resets_at: nil} =
               Backend.calculate_standing(%Backend{usage: []}, "claude-opus-5-5", now)

      odd = account.([{"Session", nil, 2}, {"Extra usage", 0.0, 2}, {"Weekly", 50.0, nil}])
      assert %{standing: 50.0, used_up: []} = Backend.calculate_standing(odd, "claude-opus-5-5", now)
    end

    test "reads a reset given in unix seconds or milliseconds, and a bare window", %{now: now} do
      in_a_day = DateTime.shift(now, day: 1)

      seconds = %Backend{
        usage: [
          %Backend.Usage{
            details: %{
              "windows" => [%{"label" => "Weekly", "remaining_percent" => 0, "resets_at" => DateTime.to_unix(in_a_day)}]
            }
          }
        ]
      }

      millis = %Backend{
        usage: [
          %Backend.Usage{
            details: %{
              "label" => "Weekly",
              "remaining_percent" => 0,
              "resets_at" => DateTime.to_unix(in_a_day, :millisecond)
            }
          },
          %Backend.Usage{
            details: %{"windows" => [%{"label" => "Weekly", "remaining_percent" => 40, "resets_at" => "soon"}]}
          },
          %Backend.Usage{details: %{}}
        ]
      }

      assert %{resets_at: ^in_a_day} = Backend.calculate_standing(seconds, "m", now)
      assert %{resets_at: from_millis} = Backend.calculate_standing(millis, "m", now)
      assert DateTime.compare(from_millis, in_a_day) == :eq
    end
  end

  test "display_name/1 and cli_name/1 name an account the same way everywhere" do
    assert Backend.display_name(%Backend{name: :claude, label: "work", account_label: "me@example.com"}) ==
             "Claude Code · work"

    assert Backend.display_name(%Backend{name: :claude, account_label: "me@example.com"}) ==
             "Claude Code · me@example.com"

    assert Backend.display_name(%Backend{name: :agy}) == "Antigravity CLI"
    assert Backend.cli_name(:codex) == "Codex"
  end
end
