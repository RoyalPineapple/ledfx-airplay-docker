# TODO

## GitHub Actions

- [ ] **Prebuild Docker images with GitHub Actions**
  - Create GitHub Actions workflow to build and push Docker images to GitHub Container Registry (ghcr.io)
  - Build `shairport-sync` image with ALAC decoder and AirPlay 2 support (`--with-apple-alac` and `--with-airplay-2` flags)
  - Build `airglow-web` image
  - Build `avahi` image
  - Build `nqptp` image
  - Tag images with version tags and `latest`
  - Update install script to use pre-built images from ghcr.io instead of building from source
  - This will significantly speed up installations and ensure consistent builds across environments

## Debugging

- [ ] **Debug AirPlay 2 support with pre-built shairport-sync image**
  - Investigate why `mikebrady/shairport-sync:latest` pre-built image starts in "classic Airplay (aka AirPlay 1) mode" instead of AirPlay 2
  - Check if the pre-built image includes AirPlay 2 support (`--with-airplay-2` flag)
  - Verify NQPTP integration with the pre-built image
  - Check if shared memory (`/dev/shm`) is properly accessible
  - Compare build flags between pre-built image and our custom build
  - Determine if we need to use a different tag/version of the pre-built image that includes AirPlay 2
  - Document findings and solution

