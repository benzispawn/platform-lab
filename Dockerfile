FROM node:24.22-trixie-slim

WORKDIR /platform-lab

COPY package.json package-lock.json ./

RUN npm ci --omit=dev

COPY src ./src

USER node

EXPOSE 3001

CMD ["node", "./src/app.ts"]