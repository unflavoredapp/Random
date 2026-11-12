#pragma once
#include <string>

// TrustCore post-sign verifier.
//
// Re-reads a signed Mach-O from disk through a fresh file descriptor (not the
// mapping the signer wrote through) and proves the embedded signature is
// consistent before the app is allowed to be packaged:
//   * every fat slice has LC_CODE_SIGNATURE inside the slice
//   * every CodeDirectory (SHA-1 and SHA-256) covers exactly up to the signature
//   * every page hash matches the bytes on disk
//   * the CMS signature blob is present
//   * optional: the Info.plist and CodeResources special slots match those files
//
// Returns false and fills strError on the first problem.
bool TCVerifyMachOFile(const std::string &strPath,
                       const std::string &strInfoPlistPath,   // "" = don't check slot 1
                       const std::string &strCodeResPath,     // "" = don't check slot 3
                       std::string &strError);
