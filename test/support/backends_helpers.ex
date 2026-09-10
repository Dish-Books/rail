defmodule RailTest.BackendsHelpers do
  @moduledoc false

  alias Rail.Backends.Schemas.CliAccount
  alias Rail.Repo

  def valid_cli_account_attrs(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])

    default_attrs = %{
      node: "local",
      backend: :claude,
      status: "ready",
      account_label: "user-#{id}@example.com",
      account_detail: "pro",
      groups: [
        %{
          "name" => "Weekly",
          "count" => 1,
          "details" => %{"windows" => [%{"label" => "Weekly · Sonnet", "remaining_percent" => 80.0}]}
        }
      ],
      fetched_at: DateTime.utc_now()
    }

    Map.merge(default_attrs, attrs)
  end

  def create_test_cli_account(attrs \\ %{}) do
    attrs = valid_cli_account_attrs(attrs)

    %CliAccount{}
    |> CliAccount.changeset(attrs)
    |> Repo.insert!()
  end

  def sample_claude_auth_json(attrs \\ %{}) do
    defaults = %{
      "loggedIn" => true,
      "email" => "alice@example.com",
      "subscriptionType" => "Pro"
    }

    Jason.encode!(Map.merge(defaults, attrs))
  end

  def sample_claude_config_json(limits \\ nil) do
    limits =
      limits ||
        [
          %{
            "group" => "session",
            "kind" => "session",
            "percent" => 20.0,
            "resets_at" => "2026-09-10T12:00:00Z"
          },
          %{
            "group" => "weekly",
            "kind" => "weekly_all",
            "scope" => %{"model" => %{"display_name" => "Sonnet 3.7"}},
            "percent" => 35.5,
            "resets_at" => "2026-09-15T12:00:00Z"
          }
        ]

    Jason.encode!(%{
      "cachedUsageUtilization" => %{
        "fetchedAtMs" => 1_725_894_000_000,
        "utilization" => %{
          "limits" => limits
        }
      }
    })
  end

  def sample_agy_usage_json(groups \\ nil) do
    groups =
      groups ||
        [
          %{
            "name" => "Gemini Models",
            "buckets" => [
              %{
                "window" => "5h",
                "remaining_fraction" => 0.85,
                "reset_time" => "2026-09-09T20:00:00Z"
              },
              %{
                "window" => "weekly",
                "remaining_fraction" => 0.60,
                "reset_time" => "2026-09-16T20:00:00Z"
              }
            ]
          }
        ]

    Jason.encode!(%{
      "status" => "SUCCESS",
      "command" => %{
        "data" => %{
          "groups" => groups
        }
      }
    })
  end

  def sample_agy_scratch_log(email \\ "alice@example.com", auth_method \\ "oauth") do
    "2026-09-09T15:00:00.123Z INFO [Auth] applyAuthResult: email=#{email}, authMethod=#{auth_method}\n"
  end
end
