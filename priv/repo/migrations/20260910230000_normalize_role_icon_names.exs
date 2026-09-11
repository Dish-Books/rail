defmodule Rail.Repo.Migrations.NormalizeRoleIconNames do
  @moduledoc """
  Role icons are now read straight off `icon_name` and must be one of the Phosphor
  classes in `Rail.Roles.Schemas.Role.icon_names/0` — those are the only ones the
  Tailwind plugin emits CSS for. Rows still holding a legacy Material or Heroicon
  name (or nothing at all) would render as an empty span, so map them across and
  fall back to the default robot icon.
  """

  use Ecto.Migration

  @mappings %{
    "hero-clipboard-document-list" => "pi-clipboard-text",
    "hero-cube-transparent" => "pi-cube",
    "hero-paint-brush" => "pi-paint-brush",
    "hero-code-bracket" => "pi-code",
    "hero-eye" => "pi-eye",
    "hero-beaker" => "pi-flask",
    "hero-shield-check" => "pi-shield-check",
    "hero-video-camera" => "pi-video-camera",
    "code" => "pi-code",
    "bug_report" => "pi-bug",
    "verified" => "pi-seal-check-fill",
    "fact_check" => "pi-check-square-fill",
    "rate_review" => "pi-chat-text-fill",
    "alt_route" => "pi-arrows-split",
    "travel_explore" => "pi-globe-hemisphere-west",
    "assignment" => "pi-clipboard-text",
    "architecture" => "pi-compass-tool",
    "palette" => "pi-palette",
    "videocam" => "pi-video-camera"
  }

  def up do
    for {legacy, phosphor} <- @mappings do
      execute("UPDATE roles SET icon_name = '#{phosphor}' WHERE icon_name = '#{legacy}'")
    end

    allowed = Enum.map_join(Rail.Roles.Schemas.Role.icon_names(), ", ", &"'#{&1}'")

    execute("""
    UPDATE roles
       SET icon_name = '#{Rail.Roles.Schemas.Role.default_icon_name()}'
     WHERE icon_name IS NULL
        OR icon_name NOT IN (#{allowed})
    """)

    alter table(:roles) do
      modify :icon_name, :text, null: false, default: Rail.Roles.Schemas.Role.default_icon_name()
    end
  end

  def down do
    alter table(:roles) do
      modify :icon_name, :text, null: true, default: nil
    end
  end
end
