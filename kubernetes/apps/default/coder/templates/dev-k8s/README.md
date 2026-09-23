# dev-k8s workspace template

Default Kubernetes-native Coder workspace template for this cluster: an
ephemeral pod (1–4 CPU, 1–8 GiB) with a persistent `/home/coder` PVC on
`ceph-rbd`. One namespace per workspace (`coder-<user>-<workspace>`),
provisioned by the coder server's in-cluster ServiceAccount (permissions
from `../app/rbac.yaml`).

The default image is the prebaked `ghcr.io/lukasparke/coder-dev` toolchain
(Dockerfile at `docker/coder-dev/`, built by GitHub Actions); minimal
distro images fall back to a first-boot `apt`/`pacman` install of git and
openssh. Autostop is a template setting, not a workspace parameter: pass
`--default-ttl 8h` to `coder templates create/push` (users can adjust
per-workspace in the dashboard); the home volume is kept either way.

The pod is stateless — anything outside `/home/coder` is lost on restart, so
bake tools into the image or use dotfiles. The `home_disk` parameter is
immutable after creation (RBD volumes don't shrink).

The startup script bootstraps `git`/`openssh-client` on base images that ship
without them, generates a per-user SSH keypair in the home volume, and
configures git for SSH-based **commit signing**.

## Private GitHub repos

Two one-time steps per user:

1. **Link the account:** Coder dashboard → Account → GitHub → Link
   (enabled by the server-side GitHub external auth configured in
   `../app/helmrelease.yaml`; requires the OAuth app secrets in SOPS
   `cluster-secrets`). Linked accounts authenticate HTTPS clones
   transparently — including the template's optional `repo` parameter.
2. **Register the signing key:** on first workspace start the agent prints
   `~/.ssh/id_ed25519.pub`; add it on GitHub → Settings → SSH and GPG keys →
   New SSH key → **Key type: Signing Key**. Signed commits show *Verified*
   when the committer email (set from the Coder profile; falls back to
   `dev@localhost`) matches an email verified on the GitHub account.

## Create / update the template

Run from a laptop with cluster access (port-forward avoids needing the
public route or an admin token on the server pod):

```sh
kubectl -n default port-forward deploy/coder 7080:7080
coder login http://localhost:7080   # first login bootstraps the admin user
coder templates create dev-k8s --default-ttl 8h --directory kubernetes/apps/default/coder/templates/dev-k8s
```

Updates after editing `main.tf`:

```sh
coder templates push dev-k8s --default-ttl 8h --directory kubernetes/apps/default/coder/templates/dev-k8s
```

`terraform init` artifacts (`.terraform/`, `.terraform.lock.hcl`) are created
by the Coder server at push time, not stored in this repo.

## Validation

```sh
terraform -chdir=<this dir> init -backend=false
terraform -chdir=<this dir> fmt -check && terraform -chdir=<this dir> validate
```
