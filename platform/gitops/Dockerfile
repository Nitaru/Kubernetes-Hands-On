# A tiny Git server for the cluster: `git daemon` over a bare repo, with push enabled.
# It lets Argo CD watch a repository without GitHub being involved, so the whole GitOps loop
# (commit, sync, self-heal) works offline and in CI. Unauthenticated on purpose: local use only.
FROM alpine:3.23
RUN apk add --no-cache git git-daemon \
 && adduser -D -u 1000 git \
 && mkdir /repos && chown git /repos
USER git
EXPOSE 9418
ENTRYPOINT ["sh", "-c", "git init -q --bare -b main /repos/shop.git && exec git daemon --reuseaddr --base-path=/repos --export-all --enable=receive-pack --informative-errors /repos"]
