FROM archlinux:base
COPY lib/ /opt/ctxd/lib/
COPY ctxd /opt/ctxd/ctxd
ENV LD_LIBRARY_PATH=/opt/ctxd/lib HOME=/data
WORKDIR /etc/ctxd
ENTRYPOINT ["/opt/ctxd/ctxd"]
