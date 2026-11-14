
type Readiness = '1' | '0';

function parseReadiness(value: string | undefined): Readiness {
    const checkValue = value == '1';
    if (!checkValue) {
        return '0';
    }
    return '1';
}

export function testReadyNess(): boolean {
    const simulate_readiness: Readiness = parseReadiness(process.env.SIMULATE_READINESS);

    return simulate_readiness == '1' ? false : true;
}