FROM docker.io/library/usernetes_base:latest
COPY cspca.llnl.gov.cer.pem /usr/local/share/ca-certificates/
COPY cspca.cer.pem /usr/local/share/ca-certificates/
COPY PAN-cspca.llnl.gov.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates