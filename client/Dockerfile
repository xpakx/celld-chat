FROM busybox:glibc AS builder

WORKDIR /app

ADD https://github.com/elm/compiler/releases/download/0.19.2/elm-0.19.2-linux-x64.gz /tmp/elm.gz
COPY --from=nginx:alpine /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

RUN gunzip -c /tmp/elm.gz > /bin/elm && \
    chmod +x /bin/elm

COPY elm.json ./
COPY src ./src

RUN elm make src/Main.elm --optimize --output=elm.js


FROM nginx:alpine

RUN rm -rf /usr/share/nginx/html/*

COPY --from=builder /app/elm.js /usr/share/nginx/html/
COPY index.html /usr/share/nginx/html/
COPY styles.css /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
