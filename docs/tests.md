# Good and Bad Tests

## Setup

- Tests for code under `lib/rail/...` use `Rail.DataCase, async: true` (defined in [test/support/data_case.ex](../test/support/data_case.ex)). It pulls in Mimic, the `Rail.Factory` (ExMachina) helpers, `RailTest.Helpers`, and `verify_on_exit!`.
- Tests for LiveViews and controllers under `lib/rail_web/...` use `RailWeb.ConnCase, async: true` (defined in [test/support/conn_case.ex](../test/support/conn_case.ex)). On top of `DataCase` it adds verified routes and `Phoenix.ConnTest`.
- Authentication and scopes come from **scopes**, not tags. Build them with `user_scope/1` (persisted or stubbed user), `temp_user_scope/1` (in-memory, when the database isn't needed), or `system_scope/0`, passing `admin:` / `linear_linked:`. Reach for these instead of assembling auth state by hand.
- Tags that vary setup: `@moduletag :shared_sandbox` (see the `setup_all` section below), `async:`.

## Arranging test data

Use the most shared mechanism that fits. **A test file must not define its own functions** - no `def`/`defp` helpers in a `*_test.exs`. A per-file helper doesn't compose across files and stops a test from being readable top-to-bottom, so every arrangement has a better home: `setup`/`setup_all` for shared context, `test/support` for something reused across files, or inline for what makes a single test distinct. This is enforced by the [`RailCredo.Checks.NoFunctionsInTests`](../credo/lib/rail_credo/checks/no_functions_in_tests.ex) lint.

1. **Factory** (`build`/`insert`) - for constructing a valid record. Composable across every file.
2. **`setup_all` block** - for context every test in the file shares (e.g. a `scope`, project), built once per module. Prefer this for shared fixtures. It requires `@moduletag :shared_sandbox`, which shares **one** DB sandbox across the whole module, so use it only for data tests read in common, never when a test asserts on a result set that must exclude other tests' rows.
3. **`setup` block** - for context that must be isolated per test: data a test mutates, or rows a test creates and then asserts are the only ones returned. Each `setup` run gets its own sandbox. Reach for it when `setup_all` doesn't work.
4. **`test/support`** - for a domain *operation* or fixture reused across multiple files (e.g. `user_scope/1`, `read_json_mock/1`). This is the only home for a named helper: put it here precisely because more than one test file relies on it.
5. **Inline** - for what makes the test distinct, above all the variable the test changes to prove its behavior.

```elixir
# BAD: a per-file helper hiding construction every test needs
defp project_with_task(scope) do
  {:ok, project} = Projects.create_project(scope, %{name: "My Project", github_repo: "foo/bar"})
  {:ok, task} = Pipeline.create_task(scope, %{project_id: project.id, title: "Do work"})
  task
end

# GOOD: shared context in setup_all, construction inline
setup_all do
  scope = user_scope()
  %{scope: scope}
end

test "...", %{scope: scope} do
  {:ok, project} = Projects.create_project(scope, %{name: "My Project", github_repo: "foo/bar"})
  {:ok, task} = Pipeline.create_task(scope, %{project_id: project.id, title: "Do work"})
  # ...
end
```

### Where an arrangement belongs

A test file defines no functions, so every piece of arranging has exactly one home. Decide by **what the value means to the test**:

- If it's the **variable the test changes to prove behavior** (its dependent variable), it stays **inline and visible** in the test body - never threaded through a helper elsewhere. A reader should see the condition under test without opening another function.
- Context that **every** test in the file needs *identically* belongs in `setup_all`; context that must be isolated per test belongs in `setup`.
- A named helper is justified only when *more than one test file* needs it - and then it lives in `test/support`, not in the test file. `user_scope/1` is the canonical example.
- **Never hide the call to the function under test.** Setup may arrange data, but the invocation of the public API being tested - and the assertion on its result - stays inline and visible in the test body.

## Test conventions

- Tests are located directly next to the file they test, not in a separate `test/` tree. The `test/` folder is only for supporting code.
- All tests should use `async: true` (with very rare exceptions).
- We aim for 100% coverage. When true 100% is not possible, use `coveralls` comments to ignore a line or block, including a reason.
- Test actions through the context module (`Rail.Projects.get_project`), never through the action module directly.
- Scope should require the minimum permissions to make the test pass.
- When a test doesn't touch the database, use `temp_user_scope/1` instead of `user_scope/1` so nothing is persisted.
- Inspect changeset errors with `errors_on(changeset)`, not by reaching into `changeset.errors`.

## Good Tests

**Integration-style**: Test through real interfaces, not mocks of internal parts.

```elixir
# GOOD: tests context behavior through public API
defmodule Rail.Projects.Actions.CreateProjectTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project

  test "creates a project" do
    scope = user_scope()

    assert {:ok, %Project{name: "Test Project"} = project} =
             Projects.create_project(scope, %{"name" => "Test Project", "github_repo" => "foo/bar"})

    assert project.id
  end
end
```

Characteristics:

- Tests behavior users/callers care about
- Uses public API only
- Survives internal refactors
- Describes WHAT, not HOW
- One logical assertion per test

## Mocking external boundaries

Mock at the *edges* of the system - outbound HTTP and other contexts - never collaborators inside the context under test.

**External HTTP** goes through Req. The default Req adapter raises on any unmocked call (configured in [lib/test_helper.exs](../lib/test_helper.exs)), so every outbound request must be matched with `Req.Test.expect/2`.

**Another context's public API** can be mocked with Mimic, but only for modules registered with `Mimic.copy/1` in [lib/test_helper.exs](../lib/test_helper.exs). Reach for this only when testing context A would otherwise force you to stand up a large graph of context B's unrelated state.

Rules of thumb:

- Mock external HTTP via `Req.Test.expect/2`.
- Mock another context's public function only to avoid building a huge graph of unrelated state.
- Never mock `Rail.Repo`, action modules directly, or anything else inside the context under test.

## Assert on the shape inside the pattern match

When checking the structure of a return value, put the expected fields directly into the `assert`'s pattern rather than binding intermediates and asserting on them afterward.

```elixir
# GOOD: the pattern itself is the spec for the expected response
assert {:ok, %Project{id: ^project_id, name: "Rail Core"}} =
         Projects.get_project(scope, project_id)
```
