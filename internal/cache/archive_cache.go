package cache

import (
	"context"
	"errors"
	"log/slog"
	"net/url"
	"path/filepath"
	"strings"

	"github.com/buildkite/agent/v4/api"
	"github.com/buildkite/agent/v4/internal/cache/store"
)

// ponytail: reuse the atomic local blob store for this POC. No eviction yet;
// bound the experiment's payload and lifetime before sharing this with users.
func (c *client) archiveStore(ctx context.Context) (*store.LocalFileBlob, error) {
	path, err := filepath.Abs(c.archivePath)
	if err != nil {
		return nil, err
	}
	path = filepath.ToSlash(path)
	if !strings.HasPrefix(path, "/") {
		path = "/" + path // Windows file URL.
	}
	u := url.URL{Scheme: "file", Path: path}
	return store.NewLocalFileBlob(ctx, u.String())
}

// A local blob is never an entry: callers must resolve and authorize an entry
// through the registry before looking here. Verify bytes before extracting,
// and fall back to the remote store if the volume is missing or corrupt.
func (c *client) readCachedArchive(ctx context.Context, digest api.CacheDigest, dest string) (*store.TransferInfo, bool) {
	if c.archivePath == "" || digest.Algorithm != "sha256" {
		return nil, false
	}
	local, err := c.archiveStore(ctx)
	if err != nil {
		slog.Warn("Archive volume unavailable; using remote store", "err", err)
		return nil, false
	}
	info, err := local.Download(ctx, digest.Value, dest)
	if err == nil {
		err = verifyBlobDigest(ctx, dest, digest)
	}
	if err != nil {
		if !errors.Is(err, store.ErrBlobNotFound) {
			slog.Warn("Archive volume read failed; using remote store", "err", err)
		}
		return nil, false
	}
	info.ArchiveCacheHit = true
	slog.Info("Archive tier: volume hit", "digest", digest.Value, "bytes", info.BytesTransferred)
	return info, true
}

// Only retain archives after a verified remote download or a committed save.
// A skipped save never copies the job's modified targets into the local tier.
func (c *client) retainArchive(ctx context.Context, path string, digest api.CacheDigest) {
	if c.archivePath == "" || digest.Algorithm != "sha256" {
		return
	}
	local, err := c.archiveStore(ctx)
	if err == nil {
		_, err = local.Upload(ctx, path, digest.Value, 0)
	}
	if err != nil {
		slog.Warn("Could not retain archive on volume; remote cache remains available", "err", err)
		return
	}
	slog.Info("Archive tier: retained on volume", "digest", digest.Value)
}
