#define private public
#include "bundle.h"
#undef private
#include "verify.h"
#include <cstdio>
int main(int argc, char **argv)
{
    // argv: app p12 prov pass parallel(0/1) [mode]
    if (argc >= 3 && std::string(argv[1]) == "verify") {
        std::string err; bool ok = TCVerifyMachOFile(argv[2], argc > 3 ? argv[3] : "", argc > 4 ? argv[4] : "", err);
        printf("verify=%d %s\n", ok, err.c_str()); return ok ? 0 : 1;
    }
    ZSignAsset asset;
    if (!asset.Init("", argv[2], argv[3], "", argv[4])) { printf("asset init failed\n"); return 2; }
    ZAppBundle b;
    bool ok = b.SignFolder(&asset, argv[1], "", "", "", "", true, false, false, true, argv[5][0] == '1');
    printf("SIGN_RESULT=%d\n", ok);
    if (ok && argc > 6 && std::string(argv[6]) == "tamper") {
        // modify a sealed resource after signing, then re-run only the seal check
        FILE *f = fopen((std::string(b.m_strAppFolder) + "/assets.bin").c_str(), "r+b"); fseek(f, 12345, SEEK_SET); fputc('Z', f); fclose(f);
        JValue root; root["path"] = "/"; root["root"] = b.m_strAppFolder;
        b.GetSignFolderInfo(b.m_strAppFolder, root, true); b.GetObjectsToSign(b.m_strAppFolder, root);
        printf("TAMPER_SEAL_CHECK=%d\n", b.VerifyResourceSeal(root));
    }
    return ok ? 0 : 1;
}
