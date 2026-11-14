FROM node:24-alpine

WORKDIR /platform-lab

COPY package.json package-lock.json ./

RUN npm ci --omit=dev

COPY src ./src

USER node

EXPOSE 3001

CMD ["node", "./src/server.ts"]