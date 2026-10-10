defmodule RailWeb.Settings.HostsLiveTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.HostRegistry
  alias Rail.Tools.Schemas.SandboxHost
  alias Rail.Tools.Workers.SyncSandboxImage
  alias Rail.Users

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    {:ok, admin} =
      Users.register_oauth_user(%{
        github_id: "hosts_admin_gh_#{id}",
        login: "hosts_admin_#{id}",
        email: "hosts_admin_#{id}@example.com",
        admin: true
      })

    {:ok, regular} =
      Users.register_oauth_user(%{github_id: "hosts_gh_#{id}", login: "hosts_#{id}", email: "hosts_#{id}@example.com"})

    %{admin_conn: log_in_user(conn, admin), regular_conn: log_in_user(conn, regular)}
  end

  test "is admin only", %{regular_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/hosts")
  end

  test "lists Rail's machine first as Local, which opens nothing, then each host", %{admin_conn: conn} do
    {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-02", ssh_address: "rail@10.0.4.12"})
    {:ok, view, _html} = live(conn, ~p"/settings/hosts")
    render_async(view)

    assert view |> element("#hosts-list tbody tr:first-child") |> render() =~ "Rail&#39;s machine"
    assert has_element?(view, "#host-row-local", "Local")
    assert has_element?(view, "#host-cpus-local", "4 of 4")
    assert has_element?(view, "#host-memory-local", "8 of 8 GB")
    assert has_element?(view, "#host-image-local", "Current")
    assert has_element?(view, "#host-status-local", "Connected")
    refute has_element?(view, "#host-row-local[phx-click]")

    assert has_element?(view, "#host-row-#{host.id}", "rail@10.0.4.12")
    assert has_element?(view, "#host-status-#{host.id}", "Inactive")
    assert has_element?(view, "#hosts-count", "Hosts · 2")
  end

  test "the note gives the headroom every host keeps and what Rail's machine holds for the browser", %{admin_conn: conn} do
    stub(Rail, :sandbox_headroom_cpus, fn -> 2 end)
    stub(Rail, :sandbox_headroom_memory_gb, fn -> 8 end)
    {:ok, view, _html} = live(conn, ~p"/settings/hosts")

    assert has_element?(
             view,
             "#hosts-note",
             "Every host keeps 2 CPUs and 8 GB back, and Rail's machine also holds 2 CPUs and 4 GB for the browser."
           )
  end

  describe "under Docker" do
    # Hosts are made before Docker is stubbed in, so none starts a connection; a test that adds
    # one through the page stops the connection that starts.
    setup do
      Req.Test.stub(Docker, fn conn -> Req.Test.json(conn, %{"NCPU" => 18, "MemTotal" => 68 * 1024 ** 3}) end)
      :ok
    end

    test "adding a host asks for a name and an address, then keeps the sheet open on it with Rail's key",
         %{admin_conn: conn} do
      stub(Rail, :sandbox_runtime, fn -> :docker end)
      {:ok, view, _html} = live(conn, ~p"/settings/hosts")
      render_async(view)

      view |> element("#add-host-button") |> render_click()

      assert view
             |> element("#add-host-form")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("input")
             |> Enum.count() == 2

      assert has_element?(view, "#add-host-sheet", "Shown on the Sandboxes page.")
      assert has_element?(view, "#add-host-sheet", "user@host, with :port when it isn't 22.")

      view |> form("#add-host-form", sandbox_host: %{name: "", ssh_address: "10.0.4.15"}) |> render_submit()
      assert has_element?(view, "#host-name-input-error", "can't be blank")
      assert has_element?(view, "#host-address-input-error", "must be user@host")

      view
      |> form("#add-host-form", sandbox_host: %{name: "build-05", ssh_address: "deploy@127.0.0.1:1"})
      |> render_submit()

      host = Repo.get_by!(SandboxHost, name: "build-05")

      on_exit(fn ->
        for {pid, _status} <- Registry.lookup(HostRegistry, host.id),
            do: DynamicSupervisor.terminate_child(Rail.Tools.HostSupervisor, pid)
      end)

      assert has_element?(view, "#host-sheet", "build-05")
      assert has_element?(view, "#host-sheet-status", "Not connected yet")
      assert has_element?(view, "#host-sheet-public-key", host.public_key)
      assert has_element?(view, "#copy-host-key[phx-hook='CopyText'][data-copy-text='#{host.public_key}']", "Copy key")
      assert has_element?(view, "#host-sheet-key-instructions", "~/.ssh/authorized_keys")
      assert has_element?(view, "#host-sheet-key-user", "deploy")

      assert has_element?(
               view,
               "#host-sheet-setup-link[href='https://github.com/Dish-Books/rail/blob/main/docs/sandbox-hosts.md']"
             )

      assert has_element?(view, "#host-row-#{host.id}[aria-selected='true']")
    end

    test "a connected host's sheet lists what it has, since when, its host key and Rail's key, and saves an edit",
         %{admin_conn: conn} do
      {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-02", ssh_address: "rail@10.0.4.12"})

      Repo.update_all(from(h in SandboxHost, where: h.id == ^host.id),
        set: [host_key_fingerprint: "SHA256:Lk3vR9pT2mX8qW1zB6nC4yH7jD0sF5gA3uE9iO2kM4Q"]
      )

      {:ok, _owner} =
        Registry.register(HostRegistry, host.id, %{
          address: host.ssh_address,
          trusted: "SHA256:Lk3vR9pT2mX8qW1zB6nC4yH7jD0sF5gA3uE9iO2kM4Q",
          state: :connected,
          since: ~U[2026-10-10 09:41:00Z],
          error: nil,
          offered: "SHA256:Lk3vR9pT2mX8qW1zB6nC4yH7jD0sF5gA3uE9iO2kM4Q",
          machine: %{cpus: 18, memory_gb: 72},
          image: :current
        })

      stub(Rail, :sandbox_runtime, fn -> :docker end)
      stub(Rail, :sandbox_headroom_cpus, fn -> 2 end)
      stub(Rail, :sandbox_headroom_memory_gb, fn -> 8 end)
      {:ok, view, _html} = live(conn, ~p"/settings/hosts")
      render_async(view)

      assert has_element?(view, "#host-cpus-#{host.id}", "16 of 18")
      assert has_element?(view, "#host-memory-#{host.id}", "64 of 72 GB")
      view |> element("#host-row-#{host.id}") |> render_click()

      assert has_element?(view, "#host-sheet-figures", "16 of 18")
      assert has_element?(view, "#host-sheet-figures", "64 of 72 GB")
      assert has_element?(view, "#host-sheet-image", "Current")
      assert has_element?(view, "#host-sheet-connected-since[datetime='2026-10-10T09:41:00Z']")
      assert has_element?(view, "#host-sheet-host-key", "SHA256:Lk3vR9pT2mX8qW1zB6nC4yH7jD0sF5gA3uE9iO2kM4Q")
      assert has_element?(view, "#host-sheet-rails-key #host-sheet-public-key", host.public_key)

      view |> form("#edit-host-form", sandbox_host: %{name: "build-02-renamed"}) |> render_change()
      view |> form("#edit-host-form", sandbox_host: %{name: "build-02-renamed"}) |> render_submit()
      assert has_element?(view, "#host-row-#{host.id}", "build-02-renamed")
      assert has_element?(view, "#host-sheet", "build-02-renamed")

      view |> form("#edit-host-form", sandbox_host: %{ssh_address: "nope"}) |> render_submit()
      assert has_element?(view, "#host-address-input-error")
    end

    test "a host whose key changed shows both keys, and Trust new key asks first and records the offered key once",
         %{admin_conn: conn} do
      {:ok, host} =
        Tools.create_sandbox_host(system_scope(), %{name: "fsn1-ax102-sandboxes-03", ssh_address: "rail@10.0.4.13:2222"})

      Repo.update_all(from(h in SandboxHost, where: h.id == ^host.id),
        set: [host_key_fingerprint: "SHA256:7Jd2pQ9vXk4mR1sT8bN3cW6yH0eL5gA2uF9iO4kZ1Qw"]
      )

      {:ok, _owner} =
        Registry.register(HostRegistry, host.id, %{
          address: host.ssh_address,
          trusted: "SHA256:7Jd2pQ9vXk4mR1sT8bN3cW6yH0eL5gA2uF9iO4kZ1Qw",
          state: :unreachable,
          since: ~U[2026-10-10 14:12:00Z],
          error: :host_key_changed,
          offered: "SHA256:Xc5nB8tR2wQ7mK1pL4vD9sH3jF6gZ0aY2eU8iO5kN1M",
          machine: %{cpus: 10, memory_gb: 40},
          image: :current
        })

      stub(Rail, :sandbox_runtime, fn -> :docker end)
      {:ok, view, _html} = live(conn, ~p"/settings/hosts")
      render_async(view)
      assert has_element?(view, "#host-status-#{host.id}", "Unreachable since")
      assert has_element?(view, "#host-status-#{host.id}-detail", "Host key changed")

      view |> element("#host-row-#{host.id}") |> render_click()
      assert has_element?(view, "#host-key-trusted", "SHA256:7Jd2pQ9vXk4mR1sT8bN3cW6yH0eL5gA2uF9iO4kZ1Qw")
      assert has_element?(view, "#host-key-offered", "SHA256:Xc5nB8tR2wQ7mK1pL4vD9sH3jF6gZ0aY2eU8iO5kN1M")

      view |> element("#trust-key-button") |> render_click()
      assert has_element?(view, "#trust-key-modal", "SHA256:Xc5nB8tR2wQ7mK1pL4vD9sH3jF6gZ0aY2eU8iO5kN1M")
      assert has_element?(view, "#trust-key-modal", "rail@10.0.4.13:2222")

      view |> element("#confirm-trust-key-button") |> render_click()
      refute has_element?(view, "#trust-key-modal")

      assert %SandboxHost{
               host_key_fingerprint: "SHA256:Xc5nB8tR2wQ7mK1pL4vD9sH3jF6gZ0aY2eU8iO5kN1M",
               updated_at: trusted_at
             } =
               Repo.get!(SandboxHost, host.id)

      # A second click that was already on its way when the modal closed.
      render_click(view, "trust", %{})
      assert %SandboxHost{updated_at: ^trusted_at} = Repo.get!(SandboxHost, host.id)
    end

    test "trusting a key the host no longer offers changes nothing and says why", %{admin_conn: conn} do
      {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-03", ssh_address: "rail@10.0.4.13"})
      Repo.update_all(from(h in SandboxHost, where: h.id == ^host.id), set: [host_key_fingerprint: "SHA256:old"])

      {:ok, _owner} =
        Registry.register(HostRegistry, host.id, %{
          address: host.ssh_address,
          trusted: "SHA256:old",
          state: :unreachable,
          since: DateTime.utc_now(),
          error: :host_key_changed,
          offered: "SHA256:new",
          machine: nil,
          image: nil
        })

      stub(Rail, :sandbox_runtime, fn -> :docker end)
      {:ok, view, _html} = live(conn, ~p"/settings/hosts")
      render_async(view)
      view |> element("#host-row-#{host.id}") |> render_click()
      view |> element("#trust-key-button") |> render_click()

      Registry.update_value(HostRegistry, host.id, &%{&1 | offered: "SHA256:newer"})
      view |> element("#confirm-trust-key-button") |> render_click()

      assert has_element?(view, "#hosts-error-banner", "The host offers a different key now")
      assert %SandboxHost{host_key_fingerprint: "SHA256:old"} = Repo.get!(SandboxHost, host.id)

      view |> element("#clear-hosts-error-button") |> render_click()
      refute has_element?(view, "#hosts-error-banner")
    end

    test "Remove host asks first, Escape only closes the question, and confirming takes the host off the list",
         %{admin_conn: conn} do
      {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-02", ssh_address: "rail@127.0.0.1:1"})
      stub(Rail, :sandbox_runtime, fn -> :docker end)

      {:ok, view, _html} = live(conn, ~p"/settings/hosts")
      render_async(view)
      view |> element("#host-row-#{host.id}") |> render_click()

      view |> element("#remove-host-button") |> render_click()
      assert has_element?(view, "#remove-host-modal", "Remove build-02")
      render_keydown(view, "close_sheet", %{"key" => "Escape"})
      refute has_element?(view, "#remove-host-modal")
      assert has_element?(view, "#host-sheet")

      view |> element("#remove-host-button") |> render_click()
      view |> element("#cancel-remove-host-button") |> render_click()
      refute has_element?(view, "#remove-host-modal")

      view |> element("#remove-host-button") |> render_click()
      view |> element("#confirm-remove-host-button") |> render_click()
      refute has_element?(view, "#host-row-#{host.id}")
      refute has_element?(view, "#host-sheet")
      assert %SandboxHost{removed_at: %DateTime{}} = Repo.get!(SandboxHost, host.id)

      render_click(view, "remove", %{})
      refute has_element?(view, "#hosts-error-banner")
    end

    test "Try again on a failed copy queues it", %{admin_conn: conn} do
      {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-04", ssh_address: "rail@10.0.4.14"})
      Repo.update_all(from(h in SandboxHost, where: h.id == ^host.id), set: [host_key_fingerprint: "SHA256:trusted"])

      {:ok, _owner} =
        Registry.register(HostRegistry, host.id, %{
          address: host.ssh_address,
          trusted: "SHA256:trusted",
          state: :connected,
          since: DateTime.utc_now(),
          error: nil,
          offered: "SHA256:trusted",
          machine: %{cpus: 18, memory_gb: 72},
          image: {:failed, "no space left on device"}
        })

      stub(Rail, :sandbox_runtime, fn -> :docker end)
      {:ok, view, _html} = live(conn, ~p"/settings/hosts")
      render_async(view)
      assert has_element?(view, "#host-image-#{host.id}", "Copy failed")
      view |> element("#host-row-#{host.id}") |> render_click()

      view |> element("#retry-copy-button") |> render_click()
      assert_enqueued(worker: SyncSandboxImage, args: %{host_id: host.id})
    end

    test "a change the host's connection broadcasts shows without a reload", %{admin_conn: conn} do
      {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-04", ssh_address: "rail@10.0.4.14"})
      Repo.update_all(from(h in SandboxHost, where: h.id == ^host.id), set: [host_key_fingerprint: "SHA256:trusted"])

      {:ok, _owner} =
        Registry.register(HostRegistry, host.id, %{
          address: host.ssh_address,
          trusted: "SHA256:trusted",
          state: :connected,
          since: DateTime.utc_now(),
          error: nil,
          offered: "SHA256:trusted",
          machine: %{cpus: 18, memory_gb: 72},
          image: :current
        })

      stub(Rail, :sandbox_runtime, fn -> :docker end)
      {:ok, view, _html} = live(conn, ~p"/settings/hosts")
      render_async(view)
      assert has_element?(view, "#host-status-#{host.id}", "Connected")

      Registry.update_value(
        HostRegistry,
        host.id,
        &%{&1 | state: :unreachable, error: :timeout, image: {:copying, 1_503_238_554, 2_254_857_830}}
      )

      send(view.pid, :sandboxes_changed)
      render_async(view)

      assert has_element?(view, "#host-status-#{host.id}", "Unreachable since")
      assert has_element?(view, "#host-status-#{host.id}-detail", "Connection timed out on 10.0.4.14 port 22.")
      assert has_element?(view, "#host-image-#{host.id}-progress", "1.4 of 2.1 GB")
    end

    test "a refusal from the context reads in the banner, and an unknown row opens nothing", %{admin_conn: conn} do
      stub(Tools, :create_sandbox_host, fn _scope, _attrs -> {:error, :not_authorized} end)
      stub(Rail, :sandbox_runtime, fn -> :docker end)
      {:ok, view, _html} = live(conn, ~p"/settings/hosts")
      render_async(view)

      render_click(view, "open_host", %{"host_id" => "hst_nobody"})
      refute has_element?(view, "#host-sheet")

      view |> element("#add-host-button") |> render_click()
      view |> form("#add-host-form", sandbox_host: %{name: "build-05", ssh_address: "rail@10.0.4.15"}) |> render_submit()
      assert has_element?(view, "#hosts-error-banner", "Only admins can change hosts.")

      view |> element("#add-host-sheet-close") |> render_click()
      refute has_element?(view, "#add-host-sheet")
    end

    test "a refused removal or retry reads in the banner and leaves the host as it was", %{admin_conn: conn} do
      {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-04", ssh_address: "rail@10.0.4.14"})
      Repo.update_all(from(h in SandboxHost, where: h.id == ^host.id), set: [host_key_fingerprint: "SHA256:trusted"])

      {:ok, _owner} =
        Registry.register(HostRegistry, host.id, %{
          address: host.ssh_address,
          trusted: "SHA256:trusted",
          state: :connected,
          since: DateTime.utc_now(),
          error: nil,
          offered: "SHA256:trusted",
          machine: %{cpus: 18, memory_gb: 72},
          image: {:failed, "no space left on device"}
        })

      stub(Tools, :remove_sandbox_host, fn _scope, _host -> {:error, :not_authorized} end)
      stub(Tools, :retry_sandbox_image_copy, fn _scope, _host -> {:error, :not_authorized} end)
      stub(Rail, :sandbox_runtime, fn -> :docker end)
      {:ok, view, _html} = live(conn, ~p"/settings/hosts")
      render_async(view)
      view |> element("#host-row-#{host.id}") |> render_click()

      view |> element("#retry-copy-button") |> render_click()
      assert has_element?(view, "#hosts-error-banner", "Only admins can change hosts.")

      view |> element("#remove-host-button") |> render_click()
      view |> element("#confirm-remove-host-button") |> render_click()
      refute has_element?(view, "#remove-host-modal")
      assert has_element?(view, "#host-row-#{host.id}")
      assert has_element?(view, "#hosts-error-banner", "Only admins can change hosts.")
    end
  end
end
