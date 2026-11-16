#!/usr/bin/env python3
"""Build the pinned NVST protocol libraries (OpenSSL, usrsctp) for tvOS and the arm64 tvOS simulator.

Uses the same pinned sources, hashes and framework layout as the iOS script next door.
"""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
_spec = importlib.util.spec_from_file_location(
    "ios_libs", ROOT / "ios/OpenNOWiOS/BuildScripts/build-native-protocol-libs.py")
ios_libs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ios_libs)
run, framework = ios_libs.run, ios_libs.framework

MINIMUM = "17.0"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cmake", default="cmake")
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    work = ROOT / "Build/native-dependencies"
    output = ROOT / "ios/OpenNOWtvOS/Frameworks"
    work.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)

    archive = work / f"openssl-{ios_libs.OPENSSL_VERSION}.tar.gz"
    if not archive.exists():
        urllib.request.urlretrieve(
            "https://github.com/openssl/openssl/releases/download/"
            f"openssl-{ios_libs.OPENSSL_VERSION}/{archive.name}", archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ios_libs.OPENSSL_SHA256:
        raise RuntimeError("OpenSSL source archive checksum mismatch")
    source = work / f"openssl-{ios_libs.OPENSSL_VERSION}"
    if not source.exists():
        with tarfile.open(archive) as contents:
            for member in contents.getmembers():
                path = (work / member.name).resolve()
                if work.resolve() not in path.parents or member.issym() or member.islnk():
                    raise RuntimeError("Unsafe source archive member")
            contents.extractall(work)
    sctp = work / "usrsctp"
    if not sctp.exists():
        run(["git", "clone", "--depth", "1", "--branch", "0.9.5.0",
             "https://github.com/sctplab/usrsctp.git", sctp])
    revision = subprocess.check_output(["git", "-C", str(sctp), "rev-parse", "HEAD"], text=True).strip()
    if revision != ios_libs.SCTP_REVISION:
        raise RuntimeError("usrsctp source revision mismatch")

    bundles = {"OpenSSL": [], "usrsctp": []}
    for sdk, configure, minimum, platform in [
        ("appletvos", "ios64-xcrun", f"-mtvos-version-min={MINIMUM}", "AppleTVOS"),
        ("appletvsimulator", "iossimulator-arm64-xcrun",
         f"-mtvos-simulator-version-min={MINIMUM}", "AppleTVSimulator"),
    ]:
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
        build = work / ("openssl-" + sdk)
        build.mkdir(exist_ok=True)
        stage = work / ("stage-" + sdk)
        # The iOS targets fit tvOS once the compiler's SDK is swapped; tvOS prohibits fork().
        run(["perl", source / "Configure", configure, f"CC=xcrun -sdk {sdk} cc",
             "no-shared", "no-tests", "no-apps", "no-module", "no-engine",
             "--prefix=" + str(stage), minimum, "-DHAVE_FORK=0", "-isysroot", sdk_path], cwd=build)
        run(["make", "-j" + str(max(1, args.jobs))], cwd=build)
        run(["make", "install_sw"], cwd=build)
        combined = stage / "libOpenSSL.a"
        run(["xcrun", "libtool", "-static", "-o", combined,
             stage / "lib/libssl.a", stage / "lib/libcrypto.a"])
        bundles["OpenSSL"].append(framework("OpenSSL", combined, stage / "include", stage, platform))

        sctp_build = work / ("sctp-" + sdk)
        run([args.cmake, "-S", sctp, "-B", sctp_build, "-G", "Unix Makefiles",
             "-DCMAKE_SYSTEM_NAME=tvOS", "-DCMAKE_OSX_SYSROOT=" + sdk_path,
             "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + MINIMUM,
             "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
             "-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG -Wno-unused-but-set-variable -Wno-strict-prototypes",
             "-Dsctp_build_programs=OFF", "-Dsctp_build_shared_lib=OFF", "-Dsctp_debug=OFF",
             "-Dsctp_inet=OFF", "-Dsctp_inet6=OFF"])
        run([args.cmake, "--build", sctp_build, "--parallel", str(max(1, args.jobs))])
        sctp_headers = stage / "sctp-headers"
        sctp_headers.mkdir(exist_ok=True)
        shutil.copy2(sctp / "usrsctplib/usrsctp.h", sctp_headers / "usrsctp.h")
        binaries = list(sctp_build.rglob("libusrsctp.a"))
        if len(binaries) != 1:
            raise RuntimeError("Expected one usrsctp archive")
        bundles["usrsctp"].append(framework("usrsctp", binaries[0], sctp_headers, stage, platform))

    for name, slices in bundles.items():
        destination = output / (name + ".xcframework")
        if destination.exists():
            shutil.rmtree(destination)
        run(["xcodebuild", "-create-xcframework", "-framework", slices[0],
             "-framework", slices[1], "-output", destination])
        print("Built", destination, flush=True)


if __name__ == "__main__":
    main()
