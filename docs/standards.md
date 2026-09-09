# Standards

This file contains the standards for how we write code for Rail. All standards are listed here but may link out to additional files for more detailed information. Test-specific standards live in [docs/tests.md](tests.md).

## Mise

We use Mise to manage our development environment and ensure all developers are running on the same version of all tools.

## Contexts

- We organize all functionality into contexts that are logically related. For example we have a projects context that manages projects and linear workspace settings, a pipeline context that manages tasks and stages, etc.
- Contexts can only call to the top level of other contexts. Anything outside of a context must call functions available on that context's top-level module (e.g. `Rail.Projects`), never reaching into another context's internals.
- Never `import` or `alias` another context's internal modules (its actions, utils, adapters, etc.). Reach another context only through its top-level module, then go through its public API. Schemas are the one exception: a schema may be aliased from any context. This is enforced by the custom Credo check `RailCredo.Checks.ActionAndUtilAccess`.
- The context module uses `defdelegate` to expose action functions, and does nothing else. Never `alias`, `import`, or fully-qualify an action module - including a sibling action in the same context. Reach every action through its context module. Logic two actions share belongs in a util.
- Utils are never added to the context module. The context module only exposes functions to other contexts; utils are internal and imported directly into action modules.

### Actions

- Actions are the functions that we expose to other contexts and are located in the actions folder of the context. Each action lives in its own file and is exposed via `defdelegate` on the context module.
- Actions contain all of the code necessary to perform the action, including database calls.
- The action's module name, the function it exposes, and its file name must all match the action (e.g. `Actions.CreateProject`, `create_project/2`, `create_project.ex`). This is enforced by the custom Credo check `RailCredo.Checks.ActionModuleNaming`.
- User facing actions should always accept scope as the first argument (this will be used for authorization and scoping).
- When an action takes a scope and a resource, pin `project_id` between them or in the query to enforce project boundary.
- Never use the `project_id` from unverified attrs. Always take it from the verified parent struct or scope.
- Always include `project_id` in queries even when pattern matching already validates it. Pattern matching guards the gate (no DB hit if unauthorized); the query filter ensures index usage and guarantees the database only touches rows for that project.
- Create dedicated actions with required inputs instead of overloading a generic action with optional params. Build required filters into the base query to keep actions straightforward.
- When a listing differs only by a filter, add the filter to the existing `list_*` action rather than creating a near-duplicate action. Reserve dedicated actions for distinct operations with their own required inputs.
- Return the post-operation record. After an action mutates a record (approve, advance, etc.), return the updated struct, not the pre-mutation one, so callers don't read stale fields like `status`, `stage_state`, or cached state.
- Avoid per-row database calls in loops and sync callbacks. Load what you need up front (preload, or one query) instead of hitting the DB inside an `Enum` iteration.
- Wrap related operations in a single Ecto transaction so that a partial failure rolls back the whole thing.
- Use `build_*` as the function name when not persisting to the DB (generated dynamically, never persisted).
- Below is an example of a context module and an action module and the formatting they should follow.

```elixir
defmodule Rail.Projects do
  alias Rail.Projects.Actions

  defdelegate create_project(scope, attrs), to: Actions.CreateProject
end

defmodule Rail.Projects.Actions.CreateProject do
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def create_project(scope, attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end
end
```

### Schemas

- The schema file is the source of truth for everything about a data model.
- Schemas contain the ecto schema and changeset for each data model.
- Schemas may also contain functions for working directly with the schema.
- Schemas can be referenced directly from other contexts.
- Schemas should also include a `factory/0` (or `factory/1` for attrs-aware factories) function for creating a test instance of the schema. Register it for ExMachina in [test/support/factory.ex](test/support/factory.ex) with `defdelegate {name}_factory, to: Schema, as: :factory` so tests can build records with `insert(:name, ...)` / `build(:name, ...)`.
- Schemas should define a custom primary key using the `UXID` type.
- Schemas should `use Rail.Schema`.
- Fields that should not be user defined such as `project_id` should be set from the parent entity/context and not castable in a changeset.
- Fields containing sensitive values such as API tokens should use the cloak ecto type and be redacted: `field :token, Rail.Types.EncryptedBinary, redact: true`.
- Put field logic (casting, nilifying related fields) in changesets, not ad-hoc in action code. This prevents future callers from bypassing the logic.
- When values come from user input, use `validate_relationships/2` in changesets.
- Prefer Ecto's built-in validators (`validate_format`, `validate_length`, `validate_number`, ...) over hand-rolled validation logic.
- Gate privileged fields by permissions or admin status; don't silently drop them.
- `cast_assoc` is for children resources. Use with caution - it's a way to bypass actions.
- Don't auto-nilify foreign keys on delete (`on_delete: :nilify_all`) without thinking through the product implications.
- Enforce invariants, don't hack around invalid state. When validation seems to break things, fix the invalid data/tests rather than weakening the validation.
- Don't build a schema's changeset + `Repo` from outside its owning context to persist data - that bypasses validation, authorization, and business logic. Always go through the context's public API. Building a changeset for form display in a LiveView is fine; the boundary is `Repo` calls.

```elixir
defmodule Rail.Projects.Schemas.Project do
  use Rail.Schema

  @primary_key {:id, UXID, autogenerate: true, prefix: "prj"}
  schema "projects" do
    field :name, :string
    field :github_repo, :string

    timestamps()
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :github_repo])
    |> validate_required([:name, :github_repo])
  end

  def factory do
    %__MODULE__{
      name: "Rail Core",
      github_repo: "example/rail"
    }
  end
end
```

### Utils

- Utils follow a similar pattern as actions, except they are not exposed and can be referenced only from inside the context.
- To use a util it should be imported into the action module and called directly - never aliased or called by its full name.
- Utils should only be used for functionality that needs to be shared across multiple actions; if it is only used in one action it should be a local private function in the action module.

```elixir
defmodule Rail.Pipeline.Actions.AdvanceStage do
  import Rail.Pipeline.Utils.StageTransition

  def advance_stage(scope, task) do
    task
    |> calculate_next_stage()
    |> do_transition()
  end
end
```

## Code Style

### Elixir conventions

- Use `and` for boolean expressions, `&&` for truthy values. `and` is stricter.
- Never use `{}` grouped aliases. One alias per line.
- Never use the em-dash character. Always use `-` instead.
- Private functions go after public functions in a module. This is enforced by the custom Credo check `RailCredo.Checks.PrivateFunctionsLast`.
- Use standard, consistent error tuples: `{:error, :not_authorized}`, `{:error, :not_found}`, etc. See the "Pattern matching" section below for how to match expected shapes.
- `with` clauses with only one clause should use `then/2` instead, but only when already in a pipe chain.
- Prefer `%{struct | key: value}` over `Map.put/3` for updates. The update syntax enforces existing keys and preserves struct integrity.
- Pure functions that compute a value should have `calculate` in the name (not `compute`).
- Prefer letting unexpected errors crash (sent to Sentry) rather than silently handling them. Don't handle errors you don't know you have.
- Prefer `cond` over extracting functions or multiple nested case/if.
- Never nest a `case` inside another `case`. When chaining pattern matches that depend on the previous one succeeding, use `with` instead - the body of `with` runs only when all clauses match, which is exactly what nested-case expresses.
- Pass structs down, not IDs, when the caller already has the full struct. Favor structs as arguments for clarity, and use the structs being matched on in function clauses.
- Don't add empty lines unnecessarily. Let the formatter handle spacing.

### Prefer inline logic over private functions

- Default to writing logic inline in the function that uses it. Don't extract a private function just because a block of code "could" be named - naming has a cost (extra indirection, harder to read top-to-bottom).
- Reach for a private function when it genuinely simplifies a larger function. The canonical case: the body of an `Enum.reduce/3` (or similar) callback - pulling the per-element logic into a named private function makes the reduce itself readable at a glance.
- If a function is only used once, consider inlining it.

### Name unused variables descriptively

- Never leave an unused variable as a bare `_`. Always give it a meaningful name prefixed with `_`, e.g. `{:error, _changeset}` instead of `{:error, _}`, `def handle_info(_msg, socket)` instead of `def handle_info(_, socket)`. The name documents what the value is even when it's discarded.

### Pattern matching

- Match the exact shapes you expect and let anything else crash (`CaseClauseError` / `FunctionClauseError`). An unexpected shape is a bug — crashing surfaces it instead of letting `{:ok, garbage}` flow downstream.
- The crash-on-unexpected-shape rule is for *internal* invariants — values your own code produced. For values crossing an external boundary (LLM tool args, request params, third-party payloads), expect variability: match the shape you want first, then fall through a general clause to a safe default instead of crashing.
- Prefer positive type guards (`is_binary`, `is_integer`, `is_map`, `is_struct(x, DateTime)`, …) over negative ones (`not is_nil`). This is enforced by the custom Credo check `RailCredo.Checks.PreferPositiveTypeGuard`.
- Order `case`/function clauses specific → general. A variable-binding pattern matches anything, so it must come last (or be constrained with a guard); otherwise it shadows the clauses below it. This is enforced by the custom Credo check `RailCredo.Checks.NilsLastInCase`, and CI compiles with `--warnings-as-errors`.

### Comments

- Don't write comments that describe *what* the code is doing — the code already says that, and such comments rot as the code changes.
- Only add a comment to explain *why* a decision was made, and only when that reasoning isn't intuitive from the code itself.
- Keep every comment to one or two lines. Never a paragraph. This includes `@moduledoc` and `@doc` bodies.
- Long rationale does not belong in code - cut it to the one line that matters.

## Integrating with External Services

- When storing ids from external services we should use the `external_id` field in the schema.
- If a table can be used for multiple services a `provider` or `backend` field should be used to differentiate between the different services.
- A separate module should be created to handle the API calls to the external service, this module should contain minimal logic.
  - API clients should use the `Req` library to make the API calls.
  - These client modules live in the context's `clients/` folder and handle API communication, not business logic.

## LiveViews

- Reserve `handle_params` for `patch` navigation (same LiveView). Use `mount` for full navigations.
- Don't use `@impl true` in LiveViews. We don't do that even though we could.
- Repo calls should never exist in LiveViews (the only exception is in tests).
- Business logic doesn't live in LiveViews. Abstract complexity out and push it to actions. `handle_event` should ideally call a single action and then change some assigns.
- Use changesets to keep state when possible. Rarely do you not need a changeset.
- Don't wrap changesets in `to_form`. Assign the changeset directly and let `<.form>` handle the conversion internally.
- Modals go outside `Layout.App`. When deleting, use a modal for confirmation.
- Use `:if={}` syntax, not `<%= if @condition do %>`.
- Don't put `cond`/`case` branching in HEEx templates - it makes them hard to read. Encode the variants as assigns (or pattern-match the assigns in a function component) and render off those.
- Use clear `show_*` conditions, not implicit conditions.
- Avoid flash messages. For success, redirect or continue.
- Use underscores in `phx-value-*` attributes: `phx-value-task_id`, not `phx-value-task-id`.
- When folding a created or updated record into a list assign, use the `update_list_item/2` helper instead of hand-rolled `[item | list]` pipelines.
- Follow existing patterns on the same page/module.

## Components

- We create all components as their own file, the component function name and file name should match for easy searching.
- Components `use RailWeb, :html` and declare their inputs with `attr/3` (and `slot/2` where needed) so the API is explicit at the call site.
- Components are exposed by using defdelegate in the `core_components.ex` file, which is automatically imported in our live views.
- Always check for existing components before creating new ones.
- Lists should always be sortable.
- Use a toggle input for on/off state (enabled, active). Use a checkbox for inclusion in a set/selection.

## Controllers

- Focus on authentication, authorization, and input validation.
- Never use `project_id` from unverified user input. Always take it from the verified context or scope.
- Don't add `@doc`/`@moduledoc` to controllers or LiveViews. They aren't a documented public API, and the route plus action name already convey intent.

## Migrations

- Always use the `text` or `citext` types for strings.
- Don't specify `type: :text` on references (e.g. `references(:projects, type: :text)`). We have that as a default in our config.
- Don't specify `primary_key` when adding a table. We have that as a default in our config.
- Build indexes on existing tables with `concurrently: true`, plus `@disable_ddl_transaction true` and `@disable_migration_lock true` in the migration.

## Hooks

- Each hook should be in its own file inside the `assets/js/hooks` folder.
- Hooks are then imported into the `assets/js/app.js` file.

## Tests and Coverage

See [docs/tests.md](tests.md) for the full test standards. In summary:

- The `test` folder is only used for supporting code, not actual tests.
- Tests should be located directly next to the file they are testing.
- All code should be covered by tests, we aim for 100% coverage. True 100% coverage is not always possible, and in those cases we use `coveralls` comments to ignore a line or block, with a reason describing why it is not possible to test.
- `async: true` should be used for all tests (with very rare exceptions).
- Testing actions should test through the interface of the context, not by calling the action function directly.
