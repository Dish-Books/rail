# Sandbox hosts

Rail runs sandboxes on its own machine, and on any extra machine running Docker that an admin adds under Settings › Hosts. Rail reaches each extra host over one SSH connection, which it holds open and reopens when it drops. It reaches the host's Docker through that connection with `docker system dial-stdio`, the same way the Docker CLI does for an `ssh://` host, so the host opens no Docker port.

Extra hosts connect only when Rail runs sandboxes in Docker (`RAIL_SANDBOX_RUNTIME=docker`). Under the local runtime the tab lists them as inactive.

## What a host needs

- **Docker and its CLI.** Rail runs `docker system dial-stdio` on the host, so the CLI must be on the SSH user's `PATH`. Leave Docker listening on its socket only. Do not open its TCP port, not even on loopback, since a sandbox on the host could reach a loopback port.
- **An SSH user in the `docker` group.** Rail signs in as the user named in the host's SSH address, such as `rail` in `rail@10.0.4.12`.
- **Rail's key in that user's `~/.ssh/authorized_keys`.** Rail makes an ed25519 key for each host when it is added, and shows the public half in the host's sheet with a Copy key button.
- **`/srv/rail` mounted at the same path as on Rail's machine.** A sandbox mounts its worktree and scratch folder at the paths Rail sees them, so the host must see the same files there.
- **The same CPU architecture as Rail's machine.** Rail copies its own sandbox image to the host as it is, and an `arm64` image does not run on an `amd64` host.

A host runs no browser and no Postgres of its own. The shared Chrome and the database both stay on Rail's machine.

## Adding a host

1. Under Settings › Hosts, press Add host and give it a name and its SSH address, `user@host`, with `:port` when SSH is not on 22.
2. The sheet stays open on the new host and shows Rail's public key. Add that line to `~/.ssh/authorized_keys` for the user in the address:

   ```sh
   echo 'ssh-ed25519 AAAA... rail@build-05' >> ~/.ssh/authorized_keys
   ```

3. Rail connects within a minute of the key being there, and the host reads Connected.

When the host's sandbox image is not the same as Rail's, Rail copies it there, one copy at a time per host. The Image column shows the copy's progress. A copy that fails says why and offers Try again.

## Checking the host key

Rail trusts the host key it is offered on the first connection and refuses any other after that. A connected host's sheet shows the key Rail recorded as `Host key SHA256:...`. Compare it with the host's own:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

If they differ, remove the host and add it again from a network you trust.

## When the host key changes

After a reinstall the host offers a new key, and Rail refuses to connect. The host reads "Unreachable" with "Host key changed", and its sheet shows the key Rail trusts and the one offered now. Check the offered key with `ssh-keygen` as above. If it matches, press Trust new key and confirm, and Rail reconnects.

## Other errors

- "Permission denied (publickey)" means the host refused Rail's key. Check that the line in `authorized_keys` is for the user in the SSH address, and that the file is not writable by other users.
- "Connection timed out" or "Connection refused" names the address and port Rail tried. Check that SSH listens there and that a firewall lets Rail's machine through.

## Removing a host

Remove host in the sheet asks first, then closes the connection and takes the host off the list. Rail keeps the host's row, so anything that ran there can still name it.
