import app from "./app.ts";
import { handleError, parseToInteger } from "./helpers/parseToNumber.helper.ts";

let PORT: number = 3000;

handleError(() => {
    PORT = parseToInteger(process.env.PORT) as number;
});

app.listen(PORT, '0.0.0.0', () => {
    console.info(`Starting server at port ${PORT}`);
});