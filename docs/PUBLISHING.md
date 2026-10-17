# Publishing artifacts

USBArc uses separate distribution channels:

| Channel | Artifact | Signing |
| --- | --- | --- |
| Public GitHub Release | `.hap` only | Unsigned, Release-mode; consumers must apply an accepted signature. |
| Local AppGallery submission materials | `.app` bundle | Dedicated release certificate and release Profile containing the approved DDK ACL. Kept local. |

Never attach an `.app`, certificate, provisioning profile, keystore, private key, password, or local submission-material archive to GitHub. Local signing settings and submission artifacts are excluded by `.gitignore`. Select exact upload paths rather than uploading an entire output directory.

The signed submission bundle for version 1.0.0 was built using DevEco Studio 26 / API 26. Official `hap-sign-tool verify-app` verification of the **outer APP** and `verify-profile` verification both succeeded. The embedded release Profile matched the signer and bundle, and included `ohos.permission.ACCESS_DDK_USB`. The application metadata reports `debug=false`. APP container signing does not imply its nested HAP is independently signed.

Both the signed local APP and unsigned public HAP still require release-mode hardware validation; the documented CH340 / ST-Link device test used the Debug build from the same application source. Signing validity does not mean an AppGallery review has passed. No AppGallery upload or review submission was performed.

DevEco Studio 26 also supports re-signing during `Build > Upload Product` using cloud-managed signing. If using that workflow, confirm the selected Profile includes the approved DDK ACL. See [Huawei's publishing guide](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-publish-app).

The three submitted screenshot candidates are 1920×1080 PNGs captured on the test MateBook. Window-only captures were scaled proportionally and padded to fit, without inventing UI content. The icon is the app's existing 1024×1024 PNG. See [the PC/2-in-1 visual asset specification](https://developer.huawei.com/consumer/en/doc/agc-help-app-visual-asset-spec-0000002277607976).
