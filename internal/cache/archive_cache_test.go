package cache

import (
	"net/url"
	"os"
	"path/filepath"
	"testing"

	"github.com/buildkite/agent/v4/api"
	"github.com/buildkite/agent/v4/internal/cache/configuration"
	"github.com/buildkite/agent/v4/logger"
)

func TestArchiveTier(t *testing.T) {
	t.Chdir(t.TempDir())
	ctx := t.Context()
	write := func(path, data string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir("data", 0o700); err != nil {
		t.Fatal(err)
	}
	write("data/value", "original")
	write("cache.yml", "caches:\n  - name: example\n    cache_key: [v1]\n    target_paths: [data]\n")
	remote := filepath.ToSlash(t.TempDir())
	if remote[0] != '/' {
		remote = "/" + remote
	}
	u := url.URL{Scheme: "file", Path: remote}
	mock := newMockAPIClient("local_file")
	c, _, err := newClient(logger.NewConsoleLogger(logger.NewTestPrinter(t), func(int) {}), mock, Config{
		BucketURL: u.String(), CacheConfigFile: "cache.yml",
	})
	if err != nil {
		t.Fatal(err)
	}
	saved, err := c.Save(ctx, "example")
	if err != nil || !saved.CacheEntryCreated {
		t.Fatalf("seed: %+v, %v", saved, err)
	}
	c.archivePath = t.TempDir()
	restore := func(want string, local bool) {
		t.Helper()
		write("data/value", "must be replaced")
		result, err := c.Restore(ctx, "example")
		if err != nil || !result.CacheRestored || result.ArchiveCacheHit != local {
			t.Fatalf("restore: restored=%t local=%t, want local=%t: %v", result.CacheRestored, result.ArchiveCacheHit, local, err)
		}
		got, err := os.ReadFile("data/value")
		if err != nil || string(got) != want {
			t.Fatalf("restored contents = %q, %v, want %q", got, err, want)
		}
	}

	// A cold volume uses the remote blob, then a warm volume needs no remote download.
	restore("original", false)
	remoteBlob := filepath.Join(filepath.FromSlash(remote), saved.Archive.Sha256Sum)
	if err := os.Rename(remoteBlob, remoteBlob+".offline"); err != nil {
		t.Fatal(err)
	}
	restore("original", true)
	if err := os.Rename(remoteBlob+".offline", remoteBlob); err != nil {
		t.Fatal(err)
	}

	// Local corruption must not invalidate a good remote entry; downloading repairs it.
	write(filepath.Join(c.archivePath, saved.Archive.Sha256Sum), "corrupt")
	restore("original", false)
	if len(mock.expireCalls) != 0 {
		t.Fatal("local corruption invalidated the remote entry")
	}
	restore("original", true)

	// Local blobs cannot resurrect an entry the registry doesn't select.
	c.caches[0].CacheKey = []configuration.KeyPart{{Source: configuration.SourceLiteral, Arg: "absent"}}
	write("data/value", "untouched")
	miss, err := c.Restore(ctx, "example")
	if err != nil || miss.CacheRestored {
		t.Fatalf("registry miss: %+v, %v", miss, err)
	}
	got, _ := os.ReadFile("data/value")
	if string(got) != "untouched" {
		t.Fatal("registry miss changed targets")
	}
	c.caches[0].CacheKey[0].Arg = "v1"

	// A skipped save cannot publish the working tree; --force publishes a new digest.
	write("data/value", "changed")
	skipped, err := c.Save(ctx, "example")
	if err != nil || skipped.CacheEntryCreated {
		t.Fatalf("skip: %+v, %v", skipped, err)
	}
	restore("original", true)
	write("data/value", "forced")
	c.force = true
	forced, err := c.Save(ctx, "example")
	if err != nil || !forced.CacheEntryCreated || forced.Archive.Sha256Sum == saved.Archive.Sha256Sum {
		t.Fatalf("force: %+v, %v", forced, err)
	}
	restore("forced", true)

	// The optional tier can fail without losing the remote cache.
	write("not-a-directory", "blocked")
	c.archivePath = "not-a-directory"
	restore("forced", false)

	// The retained bytes match the digest used by the registry.
	if err := verifyBlobDigest(ctx, filepath.Join(filepath.FromSlash(remote), forced.Archive.Sha256Sum), api.CacheDigest{
		Algorithm: "sha256", Value: forced.Archive.Sha256Sum,
	}); err != nil {
		t.Fatal(err)
	}
}
