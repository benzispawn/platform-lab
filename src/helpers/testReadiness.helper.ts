
type Readiness = '1' | '0';

function parseReadiness(value: string | undefined): Readiness {
    const checkValue = value == '0';
    if (checkValue) {
        return '0';
    }
    return '1';
}

export function testReadiNess(): boolean {
    const simulate_readiness: Readiness = parseReadiness(process.env.SIMULATE_READINESS);

    return simulate_readiness == '0' ? false : true;
}