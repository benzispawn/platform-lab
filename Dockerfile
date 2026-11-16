FROM node:24-alpine

ARG VERSION

RUN apk upgrade --no-cache

WORKDIR /platform-lab

ENV VERSION=$VERSION

COPY package.json package-lock.json ./

RUN npm ci --omit=dev

COPY src ./src

USER node

EXPOSE 3001

CMD ["node", "./src/server.ts"]