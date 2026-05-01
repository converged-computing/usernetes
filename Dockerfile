# Stage 1: build the uid-nri-plugin binary
FROM golang:1.23 AS uid-nri-builder
RUN git clone https://github.com/converged-computing/uid-nri-plugin /src
RUN cd /src && go mod tidy && go build -o /uid-nri-plugin .

# ARG BASE_IMAGE=ghcr.io/converged-computing/usernetes:node-base
ARG BASE_IMAGE=usernetes_base
# Edit this image to add / adopt for your environment
FROM ${BASE_IMAGE}
# This are private on our cluster and need to be copied to here
COPY cspca.llnl.gov.cer.pem /usr/local/share/ca-certificates/
COPY cspca.cer.pem /usr/local/share/ca-certificates/
RUN update-ca-certificates

# uid-nri-plugin: injects uid/gid mappings into every container OCI spec
# so arbitrary images work within the 2048-slot subuid allocation.
# NRI default config already uses plugin_path=/opt/nri/plugins — no config.toml changes needed.
COPY --from=uid-nri-builder /uid-nri-plugin /opt/nri/plugins/00-uid-mapper
RUN mkdir -p /opt/nri/plugins && chmod +x /opt/nri/plugins/00-uid-mapper
COPY uid-nri-plugin.service /etc/systemd/system/uid-nri-plugin.service
RUN systemctl enable uid-nri-plugin
