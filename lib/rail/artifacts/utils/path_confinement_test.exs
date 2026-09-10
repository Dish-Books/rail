defmodule Rail.Artifacts.Utils.PathConfinementTest do
  use ExUnit.Case, async: true

  import Rail.Artifacts.Utils.PathConfinement

  describe "verify_confinement/3" do
    test "accepts valid child path" do
      root = "/tmp/test_dir"
      target = "sub/file.png"
      assert {:ok, "/tmp/test_dir/sub/file.png"} = verify_confinement(root, target)
    end

    test "accepts absolute path inside root" do
      root = "/tmp/test_dir"
      target = "/tmp/test_dir/image.png"
      assert {:ok, "/tmp/test_dir/image.png"} = verify_confinement(root, target)
    end

    test "rejects path escaping with parent directory traversal" do
      root = "/tmp/test_dir"
      target = "../other_file.png"
      assert {:error, :escapes_confinement} = verify_confinement(root, target)
    end

    test "rejects prefix collision attack" do
      root = "/tmp/test_dir"
      target = "/tmp/test_directory/file.png"
      assert {:error, :escapes_confinement} = verify_confinement(root, target)
    end

    test "handles allow_root option" do
      root = "/tmp/test_dir"
      assert {:error, :escapes_confinement} = verify_confinement(root, root)
      assert {:ok, "/tmp/test_dir"} = verify_confinement(root, root, allow_root: true)
    end
  end
end
