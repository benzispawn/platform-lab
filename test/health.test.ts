import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import app from '../src/app.ts';

describe('health check', () => {
    let server: Server;
    let baseUrl: string;

    before(async () => {
        delete process.env.SIMULATE_READINESS;
        // app.listen() returns immediately, so wait for the callback before running tests
        await new Promise<void>((resolve) => {
            server = app.listen(0, () => {
                console.info("Starting test application");
                resolve();
            });
        });
        const { port } = server.address() as AddressInfo;
        baseUrl = `http://localhost:${port}`;
    });

    it('should result in a health state', async () => {
        const result = await fetch(`${baseUrl}/health/live`);

        assert.equal(result.status, 200);
        assert.deepEqual(await result.json(), { health: true, live: true });
    });

    it('should result in a ready state', async () => {
        const result = await fetch(`${baseUrl}/health/ready`);

        assert.equal(result.status, 200);
        assert.deepEqual(await result.json(), { health: true, ready: true });
    });

    it('should result 503 when SIMULATE_READINESS equal 1', async () => {
        process.env.SIMULATE_READINESS = '1';
        const result = await fetch(`${baseUrl}/health/ready`);

        assert.equal(result.status, 503);
    })

    after(() => {
        server.close();
    });
});
