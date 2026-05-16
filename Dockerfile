ARG BASE_IMAGE=docker.io/kindest/node:v1.33.0@sha256:91e9ed777db80279c22d1d1068c091b899b2078506e4a0f797fbf6e397c0b0b2
ARG CNI_PLUGINS_VERSION=v1.7.1
ARG HELM_VERSION=v3.17.3
ARG FLANNEL_VERSION=v0.26.7
ARG CALICO_VERSION=v3.30.5
FROM ${BASE_IMAGE}
COPY Dockerfile.d/SHA256SUMS.d/ /tmp/SHA256SUMS.d
ARG CNI_PLUGINS_VERSION
ARG HELM_VERSION
ARG FLANNEL_VERSION
ARG CALICO_VERSION
RUN update-ca-certificates
RUN arch="$(uname -m | sed -e s/x86_64/amd64/ -e s/aarch64/arm64/)" && \
  # CNI Plugins
  fname="cni-plugins-linux-${arch}-${CNI_PLUGINS_VERSION}.tgz" && \
  curl -o "${fname}" -fSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/${fname}" && \
  grep "${fname}" "/tmp/SHA256SUMS.d/cni-plugins-${CNI_PLUGINS_VERSION}" | sha256sum -c && \
  mkdir -p /opt/cni/bin && \
  tar xzf "${fname}" -C /opt/cni/bin && \
  rm -f "${fname}" && \
  # Helm
  fname="helm-${HELM_VERSION}-linux-${arch}.tar.gz" && \
  curl -o "${fname}" -fSL "https://get.helm.sh/${fname}" && \
  grep "${fname}" "/tmp/SHA256SUMS.d/helm-${HELM_VERSION}" | sha256sum -c && \
  tar xzf "${fname}" -C /usr/local/bin --strip-components=1 -- "linux-${arch}/helm" && \
  rm -f "${fname}" && \
  # Flannel
  fname="flannel.tgz" && \
  curl -o "${fname}" -fSL "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/${fname}" && \
  grep "${fname}" "/tmp/SHA256SUMS.d/flannel-${FLANNEL_VERSION}" | sha256sum -c && \
  tar xzf "${fname}" -C / && \
  rm -f "${fname}" && \
  # Calico (calicoctl)
  fname="calicoctl-linux-${arch}" && \
  curl -o "${fname}" -fSL "https://github.com/projectcalico/calico/releases/download/${CALICO_VERSION}/${fname}" && \
  grep "${fname}" "/tmp/SHA256SUMS.d/calico-${CALICO_VERSION}" | sha256sum -c && \
  chmod +x "${fname}" && \
  mv "${fname}" /usr/local/bin/calicoctl && \
  # Calico manifest - derive v3.31 from v3.31.5
  calico_branch="$(echo "${CALICO_VERSION}" | cut -d. -f1,2)" && \
  fname="calico.yaml" && \
  curl -o "/${fname}" -fSL "https://raw.githubusercontent.com/projectcalico/calico/refs/heads/release-${calico_branch}/manifests/calico.yaml" && \
  grep "${fname}" "/tmp/SHA256SUMS.d/calico-manifest-${CALICO_VERSION}" | sha256sum -c

# gettext-base: for `envsubst`
# moreutils: for `sponge`
# socat: for `socat` (to silence "[WARNING FileExisting-socat]" from kubeadm)
# ipset: for using calico and command line utils
RUN apt-get update && apt-get install -y --no-install-recommends \
  gettext-base \
  moreutils \
  socat \
  ipset \
  && rm -rf /var/lib/apt/lists/*
# Calico
ENV FELIX_IGNORELOOSERPF=true
ADD Dockerfile.d/etc_udev_rules.d_90-flannel-calico.rules /etc/udev/rules.d/90-flannel-calico.rules
ADD Dockerfile.d/u7s-entrypoint.sh /
ENTRYPOINT ["/u7s-entrypoint.sh", "/usr/local/bin/entrypoint", "/sbin/init"]