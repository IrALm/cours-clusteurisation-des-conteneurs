FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./

ARG APP_VERSION=1.0
ENV APP_VERSION=${APP_VERSION}

USER node
EXPOSE 3000
CMD ["node", "server.js"]
