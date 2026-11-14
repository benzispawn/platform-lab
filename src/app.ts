import express, {type Express, type Request, type Response} from 'express';
import * as dotenv from 'dotenv';
import { testReadiNess } from './helpers/testReadiness.helper.ts';

const app: Express = express();
dotenv.config();
const VERSION = process.env.VERSION || '1.0.0';

app.get('/health/live', (req: Request, res: Response) => {
    res.json({ health: true, live: true });
});

app.get('/health/ready', (req: Request, res: Response) => {
    if (!testReadiNess()) {
        return res.status(503).send('Service Unavailable');
    }
    res.json({ health: true, ready: true });
});

app.get('/version', (req: Request, res: Response) => {
    res.json({ version: VERSION });
});

export default app;