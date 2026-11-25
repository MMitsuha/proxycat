package libmihomo

import (
	"os"
	"path/filepath"
	"testing"
)

func TestBundledProfileYAMLIsValid(t *testing.T) {
	for _, name := range []string{"default-profile.yaml", "sample-profile.yaml"} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join("..", "BundledAssets", name)
			if name == "sample-profile.yaml" {
				path = filepath.Join("..", name)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", name, err)
			}
			if err := Validate(data); err != nil {
				t.Fatalf("%s is invalid: %v", name, err)
			}
		})
	}
}
