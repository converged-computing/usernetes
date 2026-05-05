# ARG BASE_IMAGE=ghcr.io/converged-computing/usernetes:node-base
ARG BASE_IMAGE=usernetes_base
# Edit this image to add / adopt for your environment
FROM ${BASE_IMAGE}
# This are private on our cluster and need to be copied to here
COPY cspca.llnl.gov.cer.pem /usr/local/share/ca-certificates/
COPY cspca.cer.pem /usr/local/share/ca-certificates/
RUN update-ca-certificates
