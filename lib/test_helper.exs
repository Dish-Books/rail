Mimic.copy(Date)
Mimic.copy(DateTime)

# Ensure that all Req calls are mocked by default
Req.default_options(adapter: fn req -> raise "Unmocked call to #{req.url}" end)

Application.ensure_all_started(:ex_machina)
ExUnit.start(capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Rail.Repo, :manual)
