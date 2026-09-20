FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /opt/xc_vm

# Base OS updates + required packages
RUN apt-get update && \
    apt-get full-upgrade -y && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      expect \
      mariadb-client \
      mariadb-server \
      wget \
      python3 \
      unzip && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
