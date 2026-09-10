Mimic.copy(Date)
Mimic.copy(DateTime)
Mimic.copy(Rail.Users)
Mimic.copy(Rail.Issues)

# Ensure that all Req calls are mocked by default
Req.default_options(adapter: fn req -> raise "Unmocked call to #{req.url}" end)

ExUnit.start(capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Rail.Repo, :manual)
