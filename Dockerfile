FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y openssl sbsigntool efitools unzip wget uuid-runtime curl sudo acl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app
RUN chmod +x /app/sbsign.sh

CMD ["/app/sbsign.sh"]