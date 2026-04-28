FROM node:20-alpine

# ssh-keygen is needed to sign certs; wget for the healthcheck.
RUN apk add --no-cache openssh-keygen wget

WORKDIR /app

COPY package*.json ./
RUN npm install --only=production && npm cache clean --force

COPY server.js .

RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001 && \
    chown -R nodejs:nodejs /app

USER nodejs

EXPOSE 3004

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --spider -q http://localhost:3004/health || exit 1

CMD ["node", "server.js"]
