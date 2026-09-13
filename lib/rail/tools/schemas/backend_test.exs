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
end
