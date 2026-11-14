
class NotANumber extends Error {
    constructor(message: string) {
        super(message)
        this.name = this.constructor.name;
    }
}

export function parseToInteger(
    value: string | null | undefined
): number | NotANumber {
    const parsed = Number(value);
    if (value?.trim() && Number.isSafeInteger(parsed)) {
        return parsed;
    }
    throw new NotANumber(`"${value}" is not an integer number.`);
}

export function handleError(callback: Function): void {
    try {
        callback();
    } catch (error: unknown) {
        if (error instanceof NotANumber) {
            process.exit(1);
        }
        throw error;
    }
}