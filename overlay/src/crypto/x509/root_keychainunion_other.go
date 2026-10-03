// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build !darwin

package x509

// keychainUnionPlatformRoots leaves loadSystemRoots to upstream on every platform but darwin.
func keychainUnionPlatformRoots() (*CertPool, bool, error) {
	return nil, false, nil
}
