FROM golang:1.22-bookworm AS builder

RUN apt-get update && apt-get install -y git libseccomp-dev pkg-config

WORKDIR /src
RUN git clone -b ipa-updates https://github.com/converged-computing/usernetes-identity.git . && \
    make  && chmod +x ./bin/*
FROM usernetes_base

COPY --from=builder /src/bin/usernetes-identity /usr/bin/usernetes-identity
COPY --from=builder /src/bin/usernetes-identity-nri /opt/nri/plugins/usernetes-identity-nri

# Private certificates and security profiles
COPY cspca.llnl.gov.cer.pem /usr/local/share/ca-certificates/
COPY cspca.cer.pem /usr/local/share/ca-certificates/
COPY PAN-cspca.llnl.gov.crt /usr/local/share/ca-certificates/
COPY Dockerfile.d/hpc-profile.json /var/lib/kubelet/seccomp/hpc-profile.json
COPY Dockerfile.d/config.toml /etc/containerd/config.toml
RUN update-ca-certificates && mkdir -p /var/lib/containerd/io.containerd.snapshotter.v1.fuse-overlayfs
