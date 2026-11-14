import express, {type Express, type Request, type Response} from 'express';
import * as dotenv from 'dotenv';

const app: Express = express();
dotenv.config();
const PORT = process.env.PORT || '3000';
const VERSION = process.env.VERSION || '1.0.0';

app.get('/health/live', (req: Request, res: Response) => {
    res.json({ health: true, live: true });
});

app.get('/health/ready', (req: Request, res: Response) => {
    res.json({ health: true, ready: true });
});

app.get('/version', (req: Request, res: Response) => {
    res.json({ version: VERSION });
});

app.listen(PORT, () => {
    console.info(`Starting server at port ${PORT}`);
});