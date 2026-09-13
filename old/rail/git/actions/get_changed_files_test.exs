defmodule Rail.Git.Actions.GetChangedFilesTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Git.ChangedFile

  test "reports untracked files as added" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "new_file.txt"), "a\nb\n")

    files = Git.get_changed_files(repo)
    added = Enum.find(files, fn f -> f.file_path == "new_file.txt" end)

    assert %ChangedFile{
             file_path: "new_file.txt",
             status: "added",
             additions: 2,
             deletions: 0
           } = added

    assert byte_size(added.content_hash) > 0
  end

  test "reports modified and deleted tracked files" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "deleted.txt"), "goodbye\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "add deleted.txt"])

    File.write!(Path.join(repo, "tracked.txt"), "one\ntwo\n")
    File.rm!(Path.join(repo, "deleted.txt"))

    files = Git.get_changed_files(repo)

    mod = Enum.find(files, fn f -> f.file_path == "tracked.txt" end)
    assert %ChangedFile{status: "modified", additions: 1} = mod
    assert byte_size(mod.content_hash) > 0

    del = Enum.find(files, fn f -> f.file_path == "deleted.txt" end)
    assert %ChangedFile{status: "deleted", deletions: 1, content_hash: nil} = del
  end

  test "reports binary untracked file with 0 additions" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "photo.jpg"), <<0xFF, 0xD8, 0x00, 0xE0>>)

    files = Git.get_changed_files(repo)
    bin = Enum.find(files, fn f -> f.file_path == "photo.jpg" end)

    assert %ChangedFile{file_path: "photo.jpg", status: "added", additions: 0} = bin
  end

  test "omits untracked files when filter is main" do
    repo = create_temp_git_repo()
    git!(repo, ["checkout", "-b", "feature"])
    File.write!(Path.join(repo, "untracked.txt"), "untracked\n")

    files = Git.get_changed_files(repo, filter: "main")
    refute Enum.any?(files, fn f -> f.file_path == "untracked.txt" end)
  end

  test "supports arbitrary revision filters" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "commit1.txt"), "c1\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "c1"])

    File.write!(Path.join(repo, "commit2.txt"), "c2\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "c2"])

    files = Git.get_changed_files(repo, filter: "HEAD~1")
    assert Enum.any?(files, fn f -> f.file_path == "commit2.txt" end)
  end

  test "handles untracked files without trailing newline and empty untracked files" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "notrail.txt"), "no newline")
    File.write!(Path.join(repo, "empty.txt"), "")

    files = Git.get_changed_files(repo)
    notrail = Enum.find(files, fn f -> f.file_path == "notrail.txt" end)
    empty = Enum.find(files, fn f -> f.file_path == "empty.txt" end)

    assert %ChangedFile{status: "added", additions: 1} = notrail
    assert %ChangedFile{status: "added", additions: 0} = empty
  end

  test "handles untracked broken symlinks gracefully" do
    repo = create_temp_git_repo()
    :file.make_symlink("nonexistent", Path.join(repo, "broken_link"))

    files = Git.get_changed_files(repo)
    refute Enum.any?(files, fn f -> f.file_path == "broken_link" end)
  end

  test "handles binary file modifications in diff" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "blob.bin"), <<0, 1, 2>>)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "add binary"])

    File.write!(Path.join(repo, "blob.bin"), <<0, 9, 8>>)
    files = Git.get_changed_files(repo)
    blob = Enum.find(files, fn f -> f.file_path == "blob.bin" end)

    assert %ChangedFile{status: "modified", additions: 0, deletions: 0} = blob
  end

  test "returns empty list on non-git directory" do
    temp_dir = System.tmp_dir!()
    loose = Path.join(temp_dir, "non_git_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    assert Git.get_changed_files(loose) == []
  end
end
